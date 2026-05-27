//! "Launch at login" registration via the per-user Run key
//! (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`). Writing the
//! host's own executable path there makes Windows start it on sign-in;
//! removing the value disables it. HKCU needs no administrator rights.
//!
//! Non-Windows builds (the cross-platform `cargo check`/`cargo test`
//! path on the dev machine) get inert stubs.

#[cfg(windows)]
pub use imp::apply;

#[cfg(not(windows))]
pub fn apply(_enabled: bool) -> anyhow::Result<()> {
    Ok(())
}

#[cfg(windows)]
mod imp {
    use anyhow::{anyhow, Context, Result};
    use std::ffi::OsStr;
    use std::iter::once;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr;
    use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
    use windows_sys::Win32::System::Registry::{
        RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegOpenKeyExW, RegSetValueExW, HKEY,
        HKEY_CURRENT_USER, KEY_WRITE, REG_OPTION_NON_VOLATILE, REG_SZ,
    };

    const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    const VALUE_NAME: &str = "RemoteDesktopHost";

    pub fn apply(enabled: bool) -> Result<()> {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    fn enable() -> Result<()> {
        let exe = std::env::current_exe().context("locate current executable")?;
        // Quote the path so spaces (e.g. "Program Files") survive the
        // way Windows parses Run-key command lines.
        let command = format!("\"{}\"", exe.display());
        let data = wide(&command);
        let byte_len = (data.len() * std::mem::size_of::<u16>()) as u32;

        let subkey = wide(RUN_KEY);
        let value_name = wide(VALUE_NAME);
        let mut hkey: HKEY = ptr::null_mut();
        // SAFETY: pointers are valid NUL-terminated UTF-16 strings / out-pointers.
        let created = unsafe {
            RegCreateKeyExW(
                HKEY_CURRENT_USER,
                subkey.as_ptr(),
                0,
                ptr::null(),
                REG_OPTION_NON_VOLATILE,
                KEY_WRITE,
                ptr::null(),
                &mut hkey,
                ptr::null_mut(),
            )
        };
        if created != ERROR_SUCCESS {
            return Err(anyhow!("couldn't open Run registry key (error {created})"));
        }
        // SAFETY: `hkey` is open; `data` lives through the call and
        // `byte_len` (including the trailing NUL) matches its length.
        let set = unsafe {
            RegSetValueExW(
                hkey,
                value_name.as_ptr(),
                0,
                REG_SZ,
                data.as_ptr() as *const u8,
                byte_len,
            )
        };
        // SAFETY: `hkey` was successfully created/opened above.
        unsafe { RegCloseKey(hkey) };
        if set != ERROR_SUCCESS {
            return Err(anyhow!("couldn't write Run registry value (error {set})"));
        }
        Ok(())
    }

    fn disable() -> Result<()> {
        let subkey = wide(RUN_KEY);
        let value_name = wide(VALUE_NAME);
        let mut hkey: HKEY = ptr::null_mut();
        // SAFETY: `subkey` is NUL-terminated UTF-16; `hkey` is a valid out-pointer.
        let opened =
            unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, subkey.as_ptr(), 0, KEY_WRITE, &mut hkey) };
        if opened == ERROR_FILE_NOT_FOUND {
            return Ok(()); // No Run key at all → nothing registered.
        }
        if opened != ERROR_SUCCESS {
            return Err(anyhow!("couldn't open Run registry key (error {opened})"));
        }
        // SAFETY: `hkey` is open and `value_name` is NUL-terminated.
        let deleted = unsafe { RegDeleteValueW(hkey, value_name.as_ptr()) };
        // SAFETY: `hkey` was successfully opened above.
        unsafe { RegCloseKey(hkey) };
        match deleted {
            ERROR_SUCCESS | ERROR_FILE_NOT_FOUND => Ok(()),
            other => Err(anyhow!(
                "couldn't delete Run registry value (error {other})"
            )),
        }
    }

    fn wide(value: &str) -> Vec<u16> {
        OsStr::new(value).encode_wide().chain(once(0)).collect()
    }
}
