import Foundation

/// A deterministic preflight for common consequential requests where guessing
/// would be surprising or expensive. It runs before model inference, so an
/// underspecified email or food order cannot begin interacting with the Mac
/// merely because the visual fallback failed to ask a question on its own.
enum ComputerUseClarificationPolicy {
    static func question(for request: ComputerUsePromptRequest) -> String? {
        let emailUserTurns = scopedEmailUserTurns(for: request)
        let emailText = emailUserTurns.joined(separator: "\n")

        if isEmailRequest(emailText) {
            return emailQuestion(for: emailText)
        }
        let foodContext = scopedFoodContext(for: request)
        let combined = foodContext.userTurns.joined(separator: "\n")
        if isFoodOrderRequest(combined) {
            return foodOrderQuestion(
                for: foodContext.userTurns,
                clarificationQuestion: foodContext.clarificationQuestion,
                currentPrompt: request.prompt)
        }
        return nil
    }

    private struct ScopedFoodContext {
        let userTurns: [String]
        let clarificationQuestion: String?
    }

    /// Food fields never cross a completed-task boundary. Preserve exactly
    /// one prior user request only when it is immediately followed by a food
    /// clarification this host is known to emit and the current prompt is the
    /// answer. This also protects hosts receiving full transcripts from older
    /// iOS clients.
    private static func scopedFoodContext(
        for request: ComputerUsePromptRequest
    ) -> ScopedFoodContext {
        guard request.conversation.count >= 2 else {
            return ScopedFoodContext(
                userTurns: [request.prompt],
                clarificationQuestion: nil)
        }
        let priorUser = request.conversation[request.conversation.count - 2]
        let assistant = request.conversation[request.conversation.count - 1]
        guard priorUser.role == .user,
              assistant.role == .assistant,
              isFoodClarification(assistant.text) else {
            return ScopedFoodContext(
                userTurns: [request.prompt],
                clarificationQuestion: nil)
        }
        return ScopedFoodContext(
            userTurns: [priorUser.text, request.prompt],
            clarificationQuestion: assistant.text)
    }

    /// Match only the finite set of questions produced by
    /// `foodClarificationQuestion`, plus the exact question used by the
    /// previous host release. Merely ending arbitrary assistant text in a
    /// question mark must not make an older order part of the new task.
    private static func isFoodClarification(_ value: String) -> Bool {
        recognizedFoodClarifications.contains(normalized(value))
    }

    /// A completed chat turn is a hard task boundary for Mail. The only prior
    /// user text that may contribute fields to the current request is the one
    /// immediately followed by a Mail clarification and then this answer.
    /// This preserves natural follow-ups without letting an older recipient,
    /// subject, body, or send/draft choice leak into a new email.
    static func scopedEmailUserTurns(
        for request: ComputerUsePromptRequest
    ) -> [String] {
        guard request.conversation.count >= 2 else { return [request.prompt] }
        let priorUser = request.conversation[request.conversation.count - 2]
        let assistant = request.conversation[request.conversation.count - 1]
        guard priorUser.role == .user,
              assistant.role == .assistant,
              isMailClarification(assistant.text) else {
            return [request.prompt]
        }
        return [priorUser.text, request.prompt]
    }

    /// Recognize only questions this host can emit while gathering the exact
    /// deterministic Mail fields. Arbitrary assistant questions do not join
    /// otherwise separate tasks.
    static func isMailClarification(_ value: String) -> Bool {
        let question = normalized(value)
        let knownQuestions: Set<String> = [
            "who should receive the email and what should it say",
            "who should receive the email please give me their name or email address",
            "what email address should i use for the to recipient",
            "what should the email say",
            "should i send the email now or create a draft for review",
        ]
        if knownQuestions.contains(question) { return true }
        return question.hasPrefix("which recipient field should i use for ")
            && question.hasSuffix(" to cc or bcc")
    }

    private static func isEmailRequest(_ value: String) -> Bool {
        let text = normalized(value)
        let mentionsEmail = containsAny(
            ["email", "e mail", "mail message"],
            in: text)
        let asksToSend = containsAny(
            ["send", "write", "compose", "draft"],
            in: text)
            || containsMatch(
                #"\b(?:email|mail)\s+(?!(?:app|inbox|message|window)\b)\S+"#,
                in: value,
                options: [.caseInsensitive])
        return mentionsEmail && asksToSend
    }

    private static func emailQuestion(for value: String) -> String? {
        let hasRecipient = containsMatch(
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            in: value,
            options: [.caseInsensitive])
            || containsMatch(
                #"\b(?:to|email|mail)\s+(?!(?:to|an?|the|my|your|someone|somebody|recipient|address|say|tell|let|ask|confirm|notify|explain|write|send)\b)[A-Z][A-Z'’.-]*"#,
                in: value,
                options: [.caseInsensitive])
            || containsMatch(
                #"\bsend\s+(?!(?:an?|the|my|your|someone|somebody)\b)[A-Z][A-Z'’.-]*\s+(?:an?\s+)?(?:email|message)\b"#,
                in: value,
                options: [.caseInsensitive])

        let hasContent = containsMatch(
            #"\b(?:say|says|saying|tell|telling|about|regarding|concerning)\b"#,
            in: value,
            options: [.caseInsensitive])
            || containsMatch(
                #"\b(?:message|email|body)\s*(?::\s*\S|is\s+\S|should\s+say\s+\S|that\s+\S)"#,
                in: value,
                options: [.caseInsensitive])
            || containsMatch(
                #"\b(?:with|and)\s+(?:the\s+)?(?:body|message)\b(?:\s*[:=]\s*\S|\s+(?:is|that)\s+\S|\s+(?!(?:is|that)\b|[:=])\S)"#,
                in: value,
                options: [.caseInsensitive])

        switch (hasRecipient, hasContent) {
        case (false, false):
            return "Who should receive the email, and what should it say?"
        case (false, true):
            return "Who should receive the email? Please give me their name or email address."
        case (true, false):
            return "What should the email say?"
        case (true, true):
            return nil
        }
    }

    private static func isFoodOrderRequest(_ value: String) -> Bool {
        let text = normalized(value)
        let explicitlyForbidsOrdering = explicitlyForbidsOrdering(in: value)
        let asksOnlyForObservedQuote = containsAny(
            ["price", "quote", "cost", "total", "eta"],
            in: text)
            && (explicitlyForbidsOrdering
                || containsAny([
                    "read only", "read only quote", "only read", "just read",
                ], in: text))
        if asksOnlyForObservedQuote {
            // Pricing/ETA is informational. Do not force the fields required
            // for a consequential order before the visual executor can read a
            // prepared cart or pause at a person-only sign-in wall.
            return false
        }
        let asksToOrder = containsAny(
            ["order", "buy", "get", "place an order"],
            in: text)
        let foodContext = containsAny([
            "uber eats", "doordash", "door dash", "grubhub", "postmates",
            "restaurant", "food", "meal", "lunch", "dinner", "breakfast",
            "takeout", "take out", "delivery", "fried rice", "pizza",
            "burger", "sandwich", "sushi", "noodles", "curry", "tacos",
        ], in: text)
        return asksToOrder && foodContext
    }

    /// Keep the scope of a natural coordinated negation inside one sentence.
    /// Normalizing punctuation before this check would make a request such as
    /// "Don't enter credentials. Order food and show me the total." look like
    /// a read-only request, even though the second sentence is consequential.
    private static func explicitlyForbidsOrdering(in value: String) -> Bool {
        let directTarget = #"(?:place\s+(?:an?\s+|the\s+)?order|order|buy|purchase|check\s*out|checkout)"#
        let proceedToCheckout = #"(?:proceed|continue|advance)\s+to\s+(?:check\s*out|checkout)"#
        let negation = #"(?:do\s+not|don['’]?t|never)"#

        if containsMatch(
            #"\b"# + negation + #"\s+(?:"# + directTarget
                + #"|"# + proceedToCheckout + #")\b"#,
            in: value,
            options: [.caseInsensitive]) {
            return true
        }

        // Covers ordinary lists such as "Don't enter credentials, change the
        // cart, check out, or place the order" without crossing a sentence or
        // semicolon into a later positive ordering instruction.
        if containsMatch(
            #"\b"# + negation + #"\b[^.!?;\n]{0,240}\b(?:or|and)\s+(?:"#
                + directTarget + #"|"# + proceedToCheckout + #")\b"#,
            in: value,
            options: [.caseInsensitive]) {
            return true
        }

        return containsMatch(
            #"\bwithout\s+(?:ordering|buying|purchasing|checking\s*out|placing\s+(?:an?\s+|the\s+)?order)\b"#,
            in: value,
            options: [.caseInsensitive])
            || containsMatch(
                #"\bstop\s+(?:before|at)\s+(?:check\s*out|checkout|placing\s+(?:an?\s+|the\s+)?order)\b"#,
                in: value,
                options: [.caseInsensitive])
    }

    private static func foodOrderQuestion(
        for userTurns: [String],
        clarificationQuestion: String?,
        currentPrompt: String
    ) -> String? {
        let combined = userTurns.joined(separator: "\n")
        let text = normalized(combined)
        var missing: [String] = []

        if !hasFoodItem(in: userTurns) {
            missing.append("what you want to order")
        }
        if !hasRestaurant(
            in: userTurns,
            clarificationQuestion: clarificationQuestion,
            currentPrompt: currentPrompt) {
            missing.append("which restaurant")
        }
        if !hasQuantity(
            in: userTurns,
            clarificationQuestion: clarificationQuestion,
            currentPrompt: currentPrompt) {
            missing.append("how many")
        }
        if !containsAny(
            ["delivery", "deliver", "address", "pickup", "pick up"],
            in: text) {
            missing.append("delivery (and which address) or pickup")
        }
        if !containsAny(
            ["uber eats", "doordash", "door dash", "grubhub", "postmates", "restaurant website"],
            in: text) {
            missing.append("which ordering app or website")
        }

        guard !missing.isEmpty else { return nil }
        return foodClarificationQuestion(for: missing)
    }

    private static func hasFoodItem(in turns: [String]) -> Bool {
        for turn in turns {
            guard let match = firstMatch(
                #"\border\s+(.+?)(?:\s+(?:from|on|using|via|through|for\s+(?:delivery|pickup))\b|[.!?]|$)"#,
                in: turn,
                options: [.caseInsensitive]),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: turn) else { continue }
            let item = normalized(String(turn[range]))
            if !item.isEmpty,
               !["food", "something", "a meal", "an order", "dinner", "lunch", "breakfast"]
                .contains(item) {
                return true
            }
        }
        return false
    }

    private static func hasQuantity(
        in turns: [String],
        clarificationQuestion: String?,
        currentPrompt: String
    ) -> Bool {
        let combined = turns.joined(separator: "\n")
        let number = #"(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|single)"#
        if containsMatch(
            #"\b(?:quantity|qty)\s*(?::|is)?\s*"# + number + #"\b"#,
            in: combined,
            options: [.caseInsensitive])
            || containsMatch(
                #"\b"# + number + #"\s+(?:orders?|servings?|portions?|plates?|bowls?|items?)\b"#,
                in: combined,
                options: [.caseInsensitive])
            || containsMatch(
                #"\b(?:an?|one)\s+order\b"#,
                in: combined,
                options: [.caseInsensitive])
            || containsMatch(
                #"\b(?:order|get|buy)\s+(?:me\s+)?"# + number + #"\b"#,
                in: combined,
                options: [.caseInsensitive]) {
            return true
        }

        let wasAskedForQuantity = clarificationQuestion?
            .lowercased().contains("how many") == true
        guard wasAskedForQuantity else { return false }
        return currentPrompt.split(separator: ",").contains { part in
            containsMatch(
                #"^\s*"# + number + #"(?:\s+orders?)?\s*$"#,
                in: String(part),
                options: [.caseInsensitive])
        }
    }

    private static func hasRestaurant(
        in turns: [String],
        clarificationQuestion: String?,
        currentPrompt: String
    ) -> Bool {
        let combined = turns.joined(separator: "\n")
        if containsMatch(
            #"\bfrom\s+(?!(?:my|our|your|a|an|the|some|favorite|favourite|usual|saved)\b)[A-Z0-9][^,.!?\n]*"#,
            in: combined,
            options: [.caseInsensitive]) {
            return true
        }

        let wasAskedForRestaurant = clarificationQuestion?
            .lowercased().contains("restaurant") == true
        guard wasAskedForRestaurant else { return false }

        let firstPart = normalized(
            currentPrompt.split(separator: ",", maxSplits: 1).first.map(String.init) ?? currentPrompt)
        guard !firstPart.isEmpty else { return false }
        let placeholders = [
            "my favorite restaurant", "my favourite restaurant", "favorite restaurant",
            "favourite restaurant", "the usual", "you choose", "any restaurant",
            "one", "one order", "two", "two orders", "delivery", "pickup",
            "yes", "yes please", "sure", "default", "whatever is cheapest",
        ]
        return !placeholders.contains(firstPart)
            && !containsAny(["order", "address", "delivery", "pickup", "pick up"], in: firstPart)
    }

    private static func naturalList(_ values: [String]) -> String {
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default:
            return values.dropLast().joined(separator: ", ") + ", and " + values.last!
        }
    }

    private static func foodClarificationQuestion(for missing: [String]) -> String {
        "Before I start the order, please tell me \(naturalList(missing))."
    }

    private static let foodClarificationFields = [
        "what you want to order",
        "which restaurant",
        "how many",
        "delivery (and which address) or pickup",
        "which ordering app or website",
    ]

    private static let recognizedFoodClarifications: Set<String> = {
        var questions: Set<String> = [
            normalized("Which restaurant, how many, and delivery or pickup?"),
        ]
        for mask in 1 ..< (1 << foodClarificationFields.count) {
            let missing = foodClarificationFields.indices.compactMap { index in
                mask & (1 << index) == 0 ? nil : foodClarificationFields[index]
            }
            questions.insert(normalized(foodClarificationQuestion(for: missing)))
        }
        return questions
    }()

    private static func containsAny(_ values: [String], in text: String) -> Bool {
        let padded = " \(normalized(text)) "
        return values.contains { padded.contains(" \(normalized($0)) ") }
    }

    private static func normalized(_ value: String) -> String {
        let mapped = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func containsMatch(
        _ pattern: String,
        in value: String,
        options: NSRegularExpression.Options = []
    ) -> Bool {
        firstMatch(pattern, in: value, options: options) != nil
    }

    private static func firstMatch(
        _ pattern: String,
        in value: String,
        options: NSRegularExpression.Options = []
    ) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: options) else { return nil }
        return regex.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value))
    }
}
