import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
enum FoundationMCPJSONSchemaError: Error, Equatable, Sendable {
    case unsupported(String)
    case invalidGeneratedArguments(String)
    case limitExceeded(String)

    var safeDescription: String {
        switch self {
        case .unsupported(let description),
             .invalidGeneratedArguments(let description),
             .limitExceeded(let description):
            return description
        }
    }
}

/// Converts the bounded JSON Schema subset advertised by MCP tools into the
/// dynamic schema accepted by Apple's on-device model. Open-ended dictionaries
/// and unconstrained schemas are rejected because Foundation Models always
/// generates a closed object shape.
@available(macOS 26.0, *)
struct FoundationMCPJSONSchemaBridge {
    static let maximumObjectProperties = 64
    static let maximumChoiceCount = 64
    static let maximumArrayElements = 64
    static let maximumSchemaDepth = 16

    let rootSchema: MCPJSONValue
    let rootName: String

    func makeGenerationSchema() throws -> GenerationSchema {
        var referenceStack = Set<String>()
        let root = try makeDynamicSchema(
            from: rootSchema,
            path: [rootName, "arguments"],
            depth: 0,
            referenceStack: &referenceStack)

        let resolvedRoot = try resolvedSchema(rootSchema, referenceStack: &referenceStack)
        guard schemaTypes(in: resolvedRoot).contains("object") || hasProperties(resolvedRoot) else {
            throw FoundationMCPJSONSchemaError.unsupported(
                "The root input schema must describe a JSON object.")
        }
        return try GenerationSchema(root: root, dependencies: [])
    }

    private func makeDynamicSchema(
        from unresolvedSchema: MCPJSONValue,
        path: [String],
        depth: Int,
        referenceStack: inout Set<String>
    ) throws -> DynamicGenerationSchema {
        guard depth <= Self.maximumSchemaDepth else {
            throw FoundationMCPJSONSchemaError.limitExceeded(
                "The input schema is nested more than 16 levels deep.")
        }
        let schema = try resolvedSchema(unresolvedSchema, referenceStack: &referenceStack)
        guard case .object(let object) = schema else {
            throw FoundationMCPJSONSchemaError.unsupported(
                "Boolean and non-object JSON Schema nodes are not supported.")
        }

        for unsupportedKey in [
            "allOf", "not", "if", "then", "else", "patternProperties",
            "dependentSchemas", "dependencies", "unevaluatedProperties",
        ] where object[unsupportedKey] != nil {
            throw FoundationMCPJSONSchemaError.unsupported(
                "The input schema uses unsupported keyword \(unsupportedKey).")
        }

        if let choices = combinatorChoices(in: object) {
            let nonNullChoices = choices.filter { !schemaTypes(in: $0).contains("null") }
            guard !nonNullChoices.isEmpty else {
                throw FoundationMCPJSONSchemaError.unsupported(
                    "A schema that only permits null cannot be generated.")
            }
            if nonNullChoices.count == 1 {
                return try makeDynamicSchema(
                    from: nonNullChoices[0],
                    path: path + ["choice"],
                    depth: depth + 1,
                    referenceStack: &referenceStack)
            }
            guard nonNullChoices.count <= Self.maximumChoiceCount else {
                throw FoundationMCPJSONSchemaError.limitExceeded(
                    "A schema has more than 64 alternatives.")
            }
            let schemas = try nonNullChoices.enumerated().map { index, choice in
                try makeDynamicSchema(
                    from: choice,
                    path: path + ["choice_\(index)"],
                    depth: depth + 1,
                    referenceStack: &referenceStack)
            }
            return DynamicGenerationSchema(
                name: schemaName(for: path + ["choice"]),
                description: boundedDescription(object["description"]),
                anyOf: schemas)
        }

        if let typeChoices = explicitTypeChoices(in: object), typeChoices.count > 1 {
            let nonNullTypes = typeChoices.filter { $0 != "null" }
            guard !nonNullTypes.isEmpty else {
                throw FoundationMCPJSONSchemaError.unsupported(
                    "A schema that only permits null cannot be generated.")
            }
            if nonNullTypes.count == 1 {
                var narrowed = object
                narrowed["type"] = .string(nonNullTypes[0])
                return try makeDynamicSchema(
                    from: .object(narrowed),
                    path: path,
                    depth: depth + 1,
                    referenceStack: &referenceStack)
            }
            let schemas = try nonNullTypes.enumerated().map { index, type in
                var narrowed = object
                narrowed["type"] = .string(type)
                return try makeDynamicSchema(
                    from: .object(narrowed),
                    path: path + ["type_\(index)"],
                    depth: depth + 1,
                    referenceStack: &referenceStack)
            }
            return DynamicGenerationSchema(
                name: schemaName(for: path + ["types"]),
                description: boundedDescription(object["description"]),
                anyOf: schemas)
        }

        if let enumValues = object["enum"] {
            let choices = try stringChoices(enumValues)
            guard !choices.isEmpty, choices.count <= Self.maximumChoiceCount else {
                throw FoundationMCPJSONSchemaError.limitExceeded(
                    "A string enumeration must contain between 1 and 64 choices.")
            }
            return DynamicGenerationSchema(
                name: schemaName(for: path + ["enum"]),
                description: boundedDescription(object["description"]),
                anyOf: choices)
        }
        if let constant = object["const"] {
            guard case .string(let value) = constant else {
                throw FoundationMCPJSONSchemaError.unsupported(
                    "Only string constants can be generated safely.")
            }
            return DynamicGenerationSchema(
                name: schemaName(for: path + ["constant"]),
                description: boundedDescription(object["description"]),
                anyOf: [value])
        }

        // Some reviewed Accessibility tools intentionally advertise `{}` for
        // a scalar AX value. Narrow that open JSON Schema to bounded scalar
        // values; do not let it become an arbitrary object or array channel.
        if isUnconstrainedScalarSchema(object) {
            return DynamicGenerationSchema(
                name: schemaName(for: path + ["scalar"]),
                description: boundedDescription(object["description"]),
                anyOf: [
                    DynamicGenerationSchema(type: String.self),
                    DynamicGenerationSchema(type: Double.self),
                    DynamicGenerationSchema(type: Bool.self),
                ])
        }

        let types = schemaTypes(in: schema)
        let primaryType = types.first ?? (hasProperties(schema) ? "object" : "")
        switch primaryType {
        case "object":
            return try makeObjectSchema(
                object,
                path: path,
                depth: depth,
                referenceStack: &referenceStack)
        case "array":
            guard let items = object["items"] else {
                throw FoundationMCPJSONSchemaError.unsupported(
                    "Array schemas must define one item schema.")
            }
            let minimum = max(0, integerValue(object["minItems"]) ?? 0)
            let declaredMaximum = integerValue(object["maxItems"])
                ?? Self.maximumArrayElements
            let maximum = min(Self.maximumArrayElements, declaredMaximum)
            guard minimum <= maximum else {
                throw FoundationMCPJSONSchemaError.limitExceeded(
                    "An array's minimum size exceeds its safe maximum.")
            }
            let itemSchema = try makeDynamicSchema(
                from: items,
                path: path + ["item"],
                depth: depth + 1,
                referenceStack: &referenceStack)
            return DynamicGenerationSchema(
                arrayOf: itemSchema,
                minimumElements: minimum,
                maximumElements: maximum)
        case "string":
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            var guides: [GenerationGuide<Int>] = []
            if let minimum = integerValue(object["minimum"]) {
                guides.append(.minimum(minimum))
            }
            if let maximum = integerValue(object["maximum"]) {
                guides.append(.maximum(maximum))
            }
            return DynamicGenerationSchema(type: Int.self, guides: guides)
        case "number":
            var guides: [GenerationGuide<Double>] = []
            if let minimum = doubleValue(object["minimum"]) {
                guides.append(.minimum(minimum))
            }
            if let maximum = doubleValue(object["maximum"]) {
                guides.append(.maximum(maximum))
            }
            return DynamicGenerationSchema(type: Double.self, guides: guides)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "null":
            throw FoundationMCPJSONSchemaError.unsupported(
                "A schema that only permits null cannot be generated.")
        default:
            throw FoundationMCPJSONSchemaError.unsupported(
                "Every input must have a supported JSON Schema type.")
        }
    }

    private func makeObjectSchema(
        _ object: [String: MCPJSONValue],
        path: [String],
        depth: Int,
        referenceStack: inout Set<String>
    ) throws -> DynamicGenerationSchema {
        if let additionalProperties = object["additionalProperties"] {
            switch additionalProperties {
            case .bool(false):
                break
            default:
                throw FoundationMCPJSONSchemaError.unsupported(
                    "Open-ended additional properties are not supported.")
            }
        }

        let properties: [String: MCPJSONValue]
        if let value = object["properties"] {
            guard case .object(let propertyObject) = value else {
                throw FoundationMCPJSONSchemaError.unsupported(
                    "The properties keyword must be an object.")
            }
            properties = propertyObject
        } else {
            properties = [:]
        }
        guard properties.count <= Self.maximumObjectProperties else {
            throw FoundationMCPJSONSchemaError.limitExceeded(
                "An object schema has more than 64 properties.")
        }

        let required = try requiredPropertyNames(object["required"])
        guard required.isSubset(of: Set(properties.keys)) else {
            throw FoundationMCPJSONSchemaError.unsupported(
                "A required property is missing from the property schema.")
        }

        let dynamicProperties = try properties.keys.sorted().map { propertyName in
            let propertySchema = properties[propertyName]!
            let generatedSchema = try makeDynamicSchema(
                from: propertySchema,
                path: path + [propertyName],
                depth: depth + 1,
                referenceStack: &referenceStack)
            return DynamicGenerationSchema.Property(
                name: propertyName,
                description: boundedDescription(descriptionValue(in: propertySchema)),
                schema: generatedSchema,
                isOptional: !required.contains(propertyName))
        }

        return DynamicGenerationSchema(
            name: schemaName(for: path),
            description: boundedDescription(object["description"]),
            properties: dynamicProperties)
    }

    private func resolvedSchema(
        _ schema: MCPJSONValue,
        referenceStack: inout Set<String>
    ) throws -> MCPJSONValue {
        guard case .object(let object) = schema,
              case .string(let reference)? = object["$ref"] else {
            return schema
        }
        guard object.count == 1 || Set(object.keys).subtracting(["$ref", "description"]).isEmpty else {
            throw FoundationMCPJSONSchemaError.unsupported(
                "A reference with sibling constraints is not supported.")
        }
        guard reference.hasPrefix("#/") else {
            throw FoundationMCPJSONSchemaError.unsupported(
                "Only local JSON Schema references are supported.")
        }
        guard referenceStack.insert(reference).inserted else {
            throw FoundationMCPJSONSchemaError.unsupported(
                "Recursive JSON Schema references are not supported.")
        }
        defer { referenceStack.remove(reference) }

        var current = rootSchema
        for rawComponent in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let component = rawComponent
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard case .object(let object) = current,
                  let next = object[component] else {
                throw FoundationMCPJSONSchemaError.unsupported(
                    "A local JSON Schema reference cannot be resolved.")
            }
            current = next
        }
        return try resolvedSchema(current, referenceStack: &referenceStack)
    }

    private func schemaName(for path: [String]) -> String {
        let raw = path.joined(separator: "_")
        let stem = FoundationMCPToolBinding.sanitizedName(raw, maximumLength: 44)
        var hash: UInt32 = 2_166_136_261
        for byte in raw.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return "MCP_\(stem)_\(String(format: "%08x", hash))"
    }
}

@available(macOS 26.0, *)
private extension FoundationMCPJSONSchemaBridge {
    func combinatorChoices(in object: [String: MCPJSONValue]) -> [MCPJSONValue]? {
        for key in ["anyOf", "oneOf"] {
            if case .array(let choices)? = object[key] {
                return choices
            }
        }
        return nil
    }

    func explicitTypeChoices(in object: [String: MCPJSONValue]) -> [String]? {
        guard let value = object["type"] else { return nil }
        switch value {
        case .string(let type):
            return [type]
        case .array(let values):
            return values.compactMap {
                if case .string(let type) = $0 { return type }
                return nil
            }
        default:
            return nil
        }
    }

    func schemaTypes(in schema: MCPJSONValue) -> [String] {
        guard case .object(let object) = schema else { return [] }
        return explicitTypeChoices(in: object) ?? []
    }

    func hasProperties(_ schema: MCPJSONValue) -> Bool {
        guard case .object(let object) = schema else { return false }
        return object["properties"] != nil
    }

    func requiredPropertyNames(_ value: MCPJSONValue?) throws -> Set<String> {
        guard let value else { return [] }
        guard case .array(let values) = value else {
            throw FoundationMCPJSONSchemaError.unsupported(
                "The required keyword must be an array of property names.")
        }
        var names = Set<String>()
        for value in values {
            guard case .string(let name) = value else {
                throw FoundationMCPJSONSchemaError.unsupported(
                    "The required keyword must contain only property names.")
            }
            names.insert(name)
        }
        return names
    }

    func stringChoices(_ value: MCPJSONValue) throws -> [String] {
        guard case .array(let values) = value else {
            throw FoundationMCPJSONSchemaError.unsupported(
                "Only string enumerations are supported.")
        }
        return try values.map { value in
            guard case .string(let string) = value else {
                throw FoundationMCPJSONSchemaError.unsupported(
                    "Only string enumerations are supported.")
            }
            return string
        }
    }

    func integerValue(_ value: MCPJSONValue?) -> Int? {
        switch value {
        case .integer(let value): return value
        case .double(let value) where value.rounded() == value
            && value >= Double(Int.min) && value <= Double(Int.max):
            return Int(value)
        default: return nil
        }
    }

    func doubleValue(_ value: MCPJSONValue?) -> Double? {
        switch value {
        case .integer(let value): return Double(value)
        case .double(let value) where value.isFinite: return value
        default: return nil
        }
    }

    func boundedDescription(_ value: MCPJSONValue?) -> String? {
        guard case .string(let description)? = value else { return nil }
        let clean = description.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar)
                ? " "
                : Character(String(scalar))
        }
        let bounded = String(String(clean).prefix(512))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? nil : bounded
    }

    func descriptionValue(in schema: MCPJSONValue) -> MCPJSONValue? {
        guard case .object(let object) = schema else { return nil }
        return object["description"]
    }

    func isUnconstrainedScalarSchema(_ object: [String: MCPJSONValue]) -> Bool {
        let metadataKeys: Set<String> = ["description", "title", "default"]
        return Set(object.keys).isSubset(of: metadataKeys)
    }
}

/// Converts generated arguments back to the MCP client's integer-preserving
/// JSON type and validates the closed schema again before a proposal is built.
@available(macOS 26.0, *)
struct FoundationMCPGeneratedContentConverter {
    static let maximumDepth = 16
    static let maximumNodes = 2_048
    static let maximumStringBytes = 64 * 1_024

    let rootSchema: MCPJSONValue
    private var nodeCount = 0
    private var stringBytes = 0

    init(rootSchema: MCPJSONValue) {
        self.rootSchema = rootSchema
    }

    mutating func convert(_ content: GeneratedContent) throws -> MCPJSONValue {
        var references = Set<String>()
        return try convert(
            content,
            expectedSchema: rootSchema,
            depth: 0,
            referenceStack: &references)
    }

    private mutating func convert(
        _ content: GeneratedContent,
        expectedSchema unresolvedSchema: MCPJSONValue,
        depth: Int,
        referenceStack: inout Set<String>
    ) throws -> MCPJSONValue {
        guard depth <= Self.maximumDepth else {
            throw FoundationMCPJSONSchemaError.limitExceeded(
                "Generated arguments are nested more than 16 levels deep.")
        }
        nodeCount += 1
        guard nodeCount <= Self.maximumNodes else {
            throw FoundationMCPJSONSchemaError.limitExceeded(
                "Generated arguments contain too many values.")
        }

        let schema = try resolvedSchema(unresolvedSchema, referenceStack: &referenceStack)
        let selectedSchema = try selectSchema(schema, for: content.kind)
        switch content.kind {
        case .null:
            guard permits(type: "null", in: schema) else {
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "A generated null value is not allowed by the tool schema.")
            }
            return .null
        case .bool(let value):
            try require(type: "boolean", in: selectedSchema)
            return .bool(value)
        case .number(let value):
            guard value.isFinite else {
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "A generated number is not finite.")
            }
            try validateNumber(value, schema: selectedSchema)
            if permits(type: "integer", in: selectedSchema),
               value.rounded() == value,
               value >= Double(Int.min), value <= Double(Int.max) {
                return .integer(Int(value))
            }
            if permits(type: "integer", in: selectedSchema),
               !permits(type: "number", in: selectedSchema) {
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "A generated integer is outside the supported range.")
            }
            try require(type: "number", in: selectedSchema)
            return .double(value)
        case .string(let value):
            try require(type: "string", in: selectedSchema)
            stringBytes += value.utf8.count
            guard stringBytes <= Self.maximumStringBytes else {
                throw FoundationMCPJSONSchemaError.limitExceeded(
                    "Generated string arguments exceed 64 KB.")
            }
            try validateString(value, schema: selectedSchema)
            return .string(value)
        case .array(let values):
            try require(type: "array", in: selectedSchema)
            guard case .object(let schemaObject) = selectedSchema,
                  let itemSchema = schemaObject["items"] else {
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "A generated array has no item schema.")
            }
            let minimum = max(0, integerValue(schemaObject["minItems"]) ?? 0)
            let maximum = min(
                FoundationMCPJSONSchemaBridge.maximumArrayElements,
                integerValue(schemaObject["maxItems"])
                    ?? FoundationMCPJSONSchemaBridge.maximumArrayElements)
            guard values.count >= minimum, values.count <= maximum else {
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "A generated array does not satisfy its size limits.")
            }
            return .array(try values.map {
                try convert(
                    $0,
                    expectedSchema: itemSchema,
                    depth: depth + 1,
                    referenceStack: &referenceStack)
            })
        case .structure(let properties, _):
            try require(type: "object", in: selectedSchema, allowPropertiesInference: true)
            guard case .object(let schemaObject) = selectedSchema else {
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "Generated object arguments do not match the tool schema.")
            }
            let propertySchemas: [String: MCPJSONValue]
            if case .object(let values)? = schemaObject["properties"] {
                propertySchemas = values
            } else {
                propertySchemas = [:]
            }
            let unknown = Set(properties.keys).subtracting(propertySchemas.keys)
            guard unknown.isEmpty else {
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "Generated arguments contain an unknown property.")
            }
            let required = try requiredPropertyNames(schemaObject["required"])
            guard required.isSubset(of: Set(properties.keys)) else {
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "Generated arguments omit a required property.")
            }
            var result: [String: MCPJSONValue] = [:]
            result.reserveCapacity(properties.count)
            for key in properties.keys.sorted() {
                guard let generatedValue = properties[key],
                      let propertySchema = propertySchemas[key] else { continue }
                result[key] = try convert(
                    generatedValue,
                    expectedSchema: propertySchema,
                    depth: depth + 1,
                    referenceStack: &referenceStack)
            }
            return .object(result)
        @unknown default:
            throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                "A generated value uses an unsupported JSON type.")
        }
    }
}

@available(macOS 26.0, *)
private extension FoundationMCPGeneratedContentConverter {
    mutating func resolvedSchema(
        _ schema: MCPJSONValue,
        referenceStack: inout Set<String>
    ) throws -> MCPJSONValue {
        guard case .object(let object) = schema,
              case .string(let reference)? = object["$ref"] else {
            return schema
        }
        guard reference.hasPrefix("#/"), referenceStack.insert(reference).inserted else {
            throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                "A generated argument schema reference is invalid.")
        }
        defer { referenceStack.remove(reference) }
        var current = rootSchema
        for rawComponent in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let component = rawComponent
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard case .object(let currentObject) = current,
                  let next = currentObject[component] else {
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "A generated argument schema reference is missing.")
            }
            current = next
        }
        return try resolvedSchema(current, referenceStack: &referenceStack)
    }

    mutating func selectSchema(
        _ schema: MCPJSONValue,
        for kind: GeneratedContent.Kind
    ) throws -> MCPJSONValue {
        guard case .object(let object) = schema else { return schema }
        for key in ["anyOf", "oneOf"] {
            if case .array(let choices)? = object[key] {
                for choice in choices {
                    var references = Set<String>()
                    let resolved = try resolvedSchema(choice, referenceStack: &references)
                    if schemaAccepts(resolved, kind: kind) {
                        return resolved
                    }
                }
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "A generated value does not match any allowed schema choice.")
            }
        }
        return schema
    }

    func schemaAccepts(_ schema: MCPJSONValue, kind: GeneratedContent.Kind) -> Bool {
        let expected: String
        switch kind {
        case .null: expected = "null"
        case .bool: expected = "boolean"
        case .number: expected = "number"
        case .string: expected = "string"
        case .array: expected = "array"
        case .structure: expected = "object"
        @unknown default: return false
        }
        if expected == "number" {
            return permits(type: "number", in: schema) || permits(type: "integer", in: schema)
        }
        return permits(type: expected, in: schema)
    }

    func permits(type: String, in schema: MCPJSONValue) -> Bool {
        guard case .object(let object) = schema else { return false }
        let metadataKeys: Set<String> = ["description", "title", "default"]
        if Set(object.keys).isSubset(of: metadataKeys) {
            return type == "string" || type == "integer"
                || type == "number" || type == "boolean"
        }
        if type == "object", object["properties"] != nil { return true }
        if type == "string", object["enum"] != nil || object["const"] != nil { return true }
        switch object["type"] {
        case .string(let value):
            return value == type
        case .array(let values):
            return values.contains(.string(type))
        default:
            return false
        }
    }

    func require(
        type: String,
        in schema: MCPJSONValue,
        allowPropertiesInference: Bool = false
    ) throws {
        if permits(type: type, in: schema) { return }
        if allowPropertiesInference, type == "object",
           case .object(let object) = schema, object["properties"] != nil { return }
        throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
            "A generated value has the wrong JSON type.")
    }

    func validateNumber(_ value: Double, schema: MCPJSONValue) throws {
        guard case .object(let object) = schema else { return }
        if let minimum = doubleValue(object["minimum"]), value < minimum {
            throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                "A generated number is below its minimum.")
        }
        if let maximum = doubleValue(object["maximum"]), value > maximum {
            throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                "A generated number is above its maximum.")
        }
    }

    func validateString(_ value: String, schema: MCPJSONValue) throws {
        guard case .object(let object) = schema else { return }
        if case .array(let values)? = object["enum"], !values.contains(.string(value)) {
            throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                "A generated string is not an allowed choice.")
        }
        if case .string(let constant)? = object["const"], value != constant {
            throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                "A generated string does not match its required constant.")
        }
        if let minimum = integerValue(object["minLength"]), value.count < minimum {
            throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                "A generated string is shorter than its minimum length.")
        }
        if let maximum = integerValue(object["maxLength"]), value.count > maximum {
            throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                "A generated string is longer than its maximum length.")
        }
    }

    func requiredPropertyNames(_ value: MCPJSONValue?) throws -> Set<String> {
        guard let value else { return [] }
        guard case .array(let values) = value else {
            throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                "The required argument schema is invalid.")
        }
        var names = Set<String>()
        for value in values {
            guard case .string(let name) = value else {
                throw FoundationMCPJSONSchemaError.invalidGeneratedArguments(
                    "The required argument schema is invalid.")
            }
            names.insert(name)
        }
        return names
    }

    func integerValue(_ value: MCPJSONValue?) -> Int? {
        switch value {
        case .integer(let value): return value
        case .double(let value) where value.rounded() == value
            && value >= Double(Int.min) && value <= Double(Int.max):
            return Int(value)
        default: return nil
        }
    }

    func doubleValue(_ value: MCPJSONValue?) -> Double? {
        switch value {
        case .integer(let value): return Double(value)
        case .double(let value) where value.isFinite: return value
        default: return nil
        }
    }
}
#endif
