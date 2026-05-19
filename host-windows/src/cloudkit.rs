use crate::{
    config::CloudKitConfig,
    credentials::{CredentialError, CredentialStore},
};
use reqwest::Method;
use serde_json::Value;
use thiserror::Error;
use url::Url;

const CLOUDKIT_BASE_URL: &str = "https://api.apple-cloudkit.com";

#[derive(Clone, Debug)]
pub struct CloudKitClient {
    http: reqwest::Client,
    config: CloudKitConfig,
    credentials: CredentialStore,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CurrentUser {
    pub user_record_name: String,
}

#[derive(Debug, Error)]
pub enum CloudKitError {
    #[error("Apple ID sign-in is required before the Windows host can run")]
    MissingWebAuthToken,
    #[error("Apple ID sign-in is required")]
    AuthenticationRequired { redirect_url: String },
    #[error("Apple ID sign-in failed or expired: {0}")]
    AuthenticationFailed(String),
    #[error("CloudKit returned {code}: {reason}")]
    Server { code: String, reason: String },
    #[error("CloudKit returned HTTP {status}: {body}")]
    HttpStatus { status: u16, body: String },
    #[error("CloudKit response was missing {0}")]
    MissingField(&'static str),
    #[error(transparent)]
    Http(#[from] reqwest::Error),
    #[error(transparent)]
    Url(#[from] url::ParseError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Credentials(#[from] CredentialError),
}

#[derive(Clone, Copy)]
enum WebAuth {
    Omit,
    Required,
}

impl CloudKitClient {
    pub fn new(config: CloudKitConfig, credentials: CredentialStore) -> Self {
        Self {
            http: reqwest::Client::new(),
            config,
            credentials,
        }
    }

    pub async fn current_user(&self) -> Result<CurrentUser, CloudKitError> {
        let value = self.get_authenticated("public", "users/caller").await?;
        current_user_from_value(&value)
    }

    pub async fn authentication_redirect_url(&self) -> Result<String, CloudKitError> {
        match self.get_unauthenticated("public", "users/caller").await {
            Err(CloudKitError::AuthenticationRequired { redirect_url })
                if !redirect_url.is_empty() =>
            {
                Ok(redirect_url)
            }
            Err(CloudKitError::AuthenticationRequired { .. }) => {
                Err(CloudKitError::MissingField("redirectURL"))
            }
            Err(error) => Err(error),
            Ok(_) => Err(CloudKitError::Server {
                code: "AUTHENTICATION_NOT_REQUIRED".to_string(),
                reason: "CloudKit unexpectedly allowed the request without Apple ID sign-in"
                    .to_string(),
            }),
        }
    }

    pub async fn get_unauthenticated(
        &self,
        database: &str,
        operation_path: &str,
    ) -> Result<Value, CloudKitError> {
        self.send(Method::GET, database, operation_path, None, WebAuth::Omit)
            .await
    }

    pub async fn get_authenticated(
        &self,
        database: &str,
        operation_path: &str,
    ) -> Result<Value, CloudKitError> {
        self.send(
            Method::GET,
            database,
            operation_path,
            None,
            WebAuth::Required,
        )
        .await
    }

    pub async fn post_authenticated(
        &self,
        database: &str,
        operation_path: &str,
        body: &Value,
    ) -> Result<Value, CloudKitError> {
        self.send(
            Method::POST,
            database,
            operation_path,
            Some(body),
            WebAuth::Required,
        )
        .await
    }

    async fn send(
        &self,
        method: Method,
        database: &str,
        operation_path: &str,
        body: Option<&Value>,
        web_auth: WebAuth,
    ) -> Result<Value, CloudKitError> {
        let web_auth_token = match web_auth {
            WebAuth::Omit => None,
            WebAuth::Required => Some(
                self.credentials
                    .web_auth_token()?
                    .ok_or(CloudKitError::MissingWebAuthToken)?,
            ),
        };

        let url = self.url(database, operation_path, web_auth_token.as_deref())?;
        let mut request = self.http.request(method, url);
        if let Some(body) = body {
            request = request.json(body);
        }

        let response = request.send().await?;
        let status = response.status();
        let text = response.text().await?;
        let value = if text.trim().is_empty() {
            Value::Object(Default::default())
        } else {
            serde_json::from_str::<Value>(&text)?
        };

        if !status.is_success() {
            if let Some(error) = cloudkit_error_from_value(&value) {
                self.clear_token_if_auth_failed(&error)?;
                return Err(error);
            }
            return Err(CloudKitError::HttpStatus {
                status: status.as_u16(),
                body: text,
            });
        }

        self.store_rotated_web_auth_token(&value)?;
        if let Some(error) = cloudkit_error_from_value(&value) {
            self.clear_token_if_auth_failed(&error)?;
            return Err(error);
        }

        Ok(value)
    }

    fn url(
        &self,
        database: &str,
        operation_path: &str,
        web_auth_token: Option<&str>,
    ) -> Result<Url, CloudKitError> {
        let operation_path = operation_path.trim_start_matches('/');
        let mut url = Url::parse(&format!(
            "{CLOUDKIT_BASE_URL}/database/1/{}/{}/{}/{}",
            self.config.container_identifier,
            self.config.environment.as_str(),
            database,
            operation_path
        ))?;
        {
            let mut query = url.query_pairs_mut();
            query.append_pair("ckAPIToken", &self.config.api_token);
            if let Some(token) = web_auth_token {
                query.append_pair("ckWebAuthToken", token);
            }
        }
        Ok(url)
    }

    fn store_rotated_web_auth_token(&self, value: &Value) -> Result<(), CredentialError> {
        if let Some(token) = web_auth_token_from_value(value) {
            self.credentials.set_web_auth_token(token)?;
        }
        Ok(())
    }

    fn clear_token_if_auth_failed(&self, error: &CloudKitError) -> Result<(), CredentialError> {
        if matches!(
            error,
            CloudKitError::AuthenticationRequired { .. } | CloudKitError::AuthenticationFailed(_)
        ) {
            self.credentials.clear_web_auth_token()?;
        }
        Ok(())
    }
}

fn cloudkit_error_from_value(value: &Value) -> Option<CloudKitError> {
    let code = value.get("serverErrorCode")?.as_str()?.to_string();
    let reason = value
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or("CloudKit request failed")
        .to_string();

    match code.as_str() {
        "AUTHENTICATION_REQUIRED" => Some(CloudKitError::AuthenticationRequired {
            redirect_url: value
                .get("redirectURL")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        }),
        "AUTHENTICATION_FAILED" | "NOT_AUTHENTICATED" => {
            Some(CloudKitError::AuthenticationFailed(reason))
        }
        _ => Some(CloudKitError::Server { code, reason }),
    }
}

fn web_auth_token_from_value(value: &Value) -> Option<&str> {
    value
        .get("ckWebAuthToken")
        .or_else(|| value.get("webAuthToken"))
        .and_then(Value::as_str)
        .filter(|token| !token.trim().is_empty())
}

fn current_user_from_value(value: &Value) -> Result<CurrentUser, CloudKitError> {
    if let Some(record_name) = value.get("userRecordName").and_then(Value::as_str) {
        return Ok(CurrentUser {
            user_record_name: record_name.to_string(),
        });
    }

    let record_name = value
        .get("users")
        .and_then(Value::as_array)
        .and_then(|users| users.first())
        .and_then(|user| user.get("userRecordName"))
        .and_then(Value::as_str)
        .ok_or(CloudKitError::MissingField("users[0].userRecordName"))?;

    Ok(CurrentUser {
        user_record_name: record_name.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn extracts_authentication_redirect_error() {
        let value = json!({
            "serverErrorCode": "AUTHENTICATION_REQUIRED",
            "reason": "request needs authorization",
            "redirectURL": "https://idmsa.apple.com/example"
        });

        let error = cloudkit_error_from_value(&value).unwrap();
        assert!(matches!(
            error,
            CloudKitError::AuthenticationRequired { redirect_url }
                if redirect_url == "https://idmsa.apple.com/example"
        ));
    }

    #[test]
    fn extracts_rotated_web_auth_token() {
        let value = json!({ "ckWebAuthToken": "next-token" });
        assert_eq!(web_auth_token_from_value(&value), Some("next-token"));
    }

    #[test]
    fn parses_current_user_identity_response() {
        let value = json!({ "users": [{ "userRecordName": "_abc123" }] });
        let user = current_user_from_value(&value).unwrap();
        assert_eq!(user.user_record_name, "_abc123");
    }
}
