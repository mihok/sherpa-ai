#if canImport(FoundationModels)
  import Foundation
  import FoundationModels

  /// Maps the schema IR built in Dart (lib/src/fm/fm_schema.dart) onto
  /// `DynamicGenerationSchema` and `GenerationSchema(root:dependencies:)`.
  /// All conversion decisions are Dart's; this is a 1:1 constructor walk.
  @available(iOS 26.0, macOS 26.0, *)
  enum FmSchemaBuilder {
    final class Node: Decodable {
      let kind: String
      let name: String?
      let description: String?
      let properties: [Property]?
      let items: Node?
      let minItems: Int?
      let maxItems: Int?
      let anyOf: [String]?
      let constant: String?
      let pattern: String?
      let minimum: Double?
      let maximum: Double?
      let choices: [Node]?
    }

    final class Property: Decodable {
      let name: String
      let description: String?
      let optional: Bool?
      let schema: Node
    }

    struct Document: Decodable {
      let root: Node
      let dependencies: [Node]
    }

    static func schema(from json: String) throws -> GenerationSchema {
      guard let data = json.data(using: .utf8) else {
        throw PluginError.make(.invalidRequest, "schema is not UTF-8")
      }
      let doc = try JSONDecoder().decode(Document.self, from: data)
      return try GenerationSchema(root: build(doc.root), dependencies: doc.dependencies.map(build))
    }

    static func build(_ n: Node) throws -> DynamicGenerationSchema {
      switch n.kind {
      case "object":
        let properties = try (n.properties ?? []).map { p in
          DynamicGenerationSchema.Property(
            name: p.name, description: p.description, schema: try build(p.schema), isOptional: p.optional ?? false)
        }
        return DynamicGenerationSchema(name: n.name ?? "Object", description: n.description, properties: properties)
      case "string":
        var guides: [GenerationGuide<String>] = []
        if let values = n.anyOf, !values.isEmpty {
          guides.append(.anyOf(values))
        } else if let c = n.constant {
          guides.append(.constant(c))
        } else if let p = n.pattern, let regex = try? Regex(p) {
          guides.append(.pattern(regex))
        }
        return DynamicGenerationSchema(type: String.self, guides: guides)
      case "integer":
        var guides: [GenerationGuide<Int>] = []
        if let lo = n.minimum { guides.append(.minimum(Int(lo))) }
        if let hi = n.maximum { guides.append(.maximum(Int(hi))) }
        return DynamicGenerationSchema(type: Int.self, guides: guides)
      case "number":
        var guides: [GenerationGuide<Double>] = []
        if let lo = n.minimum { guides.append(.minimum(lo)) }
        if let hi = n.maximum { guides.append(.maximum(hi)) }
        return DynamicGenerationSchema(type: Double.self, guides: guides)
      case "boolean":
        return DynamicGenerationSchema(type: Bool.self)
      case "array":
        guard let items = n.items else { return DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self)) }
        return DynamicGenerationSchema(
          arrayOf: try build(items), minimumElements: n.minItems, maximumElements: n.maxItems)
      case "anyOf":
        return DynamicGenerationSchema(
          name: n.name ?? "Choice", description: n.description, anyOf: try (n.choices ?? []).map(build))
      case "ref":
        return DynamicGenerationSchema(referenceTo: n.name ?? "")
      default:
        return DynamicGenerationSchema(type: String.self)
      }
    }
  }
#endif
