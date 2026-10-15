#!/usr/bin/env swift
// Writes Sources/ProductPageKitASC/openapi.json from Apple's App Store Connect
// OpenAPI document, with the two changes swift-openapi-generator needs:
//
//   swift Scripts/vendor-openapi.swift <path to Apple's openapi.oas.json>
//
// Download Apple's document from
// https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
//
// 1. A string schema with an empty `enum` loses the `enum`. Apple ships some
//    (`fields[appKeywords]`), and an enum with no cases does not compile.
//    Under `components`, so does every enum with more than one value: App
//    Store Connect adds states, display types and placement types without a
//    new document, and a closed Swift enum then fails to decode the whole
//    response. Single-value enums, the JSON:API `type` of each resource, stay.
// 2. An object schema that has `properties` loses an `anyOf` or `oneOf` whose
//    branches only list required keys. Apple writes which combinations of
//    relationships are valid that way (a placement needs an image or a video,
//    and one parent); the branches add no shape, and the generator turns each
//    into an empty payload type that never encodes.
// 3. A `oneOf` whose discriminator names a property none of its branches
//    have becomes an `allOf` of the branches. Apple discriminates a
//    placement's relationships by `mediaType`, which is an attribute, so the
//    generated decoder could never find it and every placement would fail to
//    decode. Every branch property is optional, so the merged object decodes
//    whichever relationship is there.
// 4. The 200 response of every to-one relationship GET (`…_getToOneRelated`)
//    has an optional, nullable `data`. JSON:API answers `"data": null` when
//    nothing is related, such as a version without App Review details, and
//    Apple's schemas mark `data` required.
// 5. Every GET with a `limit` gains a `cursor` query parameter. Apple pages
//    collections with a `links.next` URL whose `cursor` is not in the
//    document, so without it the generated client cannot ask for page two.

import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift Scripts/vendor-openapi.swift <openapi.oas.json>\n".utf8))
    exit(64)
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Sources/ProductPageKitASC/openapi.json")

var document = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]

/// A schema that says which keys are required and nothing about their types.
func onlyConstrains(_ value: Any) -> Bool {
    guard let object = value as? [String: Any] else { return false }
    let shapeless: Set<String> = ["required", "type"]
    guard Set(object.keys).isSubset(of: shapeless.union(["properties"])),
          object["type"] == nil || object["type"] as? String == "object"
    else { return false }
    let properties = object["properties"] as? [String: Any] ?? [:]
    return properties.values.allSatisfy(onlyConstrains)
}

var removedEnums = 0
var removedConstraints = 0

func patched(_ value: Any, openEnums: Bool) -> Any {
    if var object = value as? [String: Any] {
        if let cases = object["enum"] as? [Any], cases.isEmpty || (openEnums && cases.count > 1) {
            object.removeValue(forKey: "enum")
            removedEnums += 1
        }
        if object["properties"] != nil {
            for key in ["anyOf", "oneOf"] {
                if let branches = object[key] as? [Any], branches.allSatisfy(onlyConstrains) {
                    object.removeValue(forKey: key)
                    removedConstraints += 1
                }
            }
        }
        return object.mapValues { patched($0, openEnums: openEnums) }
    }
    if let array = value as? [Any] {
        return array.map { patched($0, openEnums: openEnums) }
    }
    return value
}

document["paths"] = patched(document["paths"]!, openEnums: false)
document["components"] = patched(document["components"]!, openEnums: true)

var components = document["components"] as! [String: Any]
var schemas = components["schemas"] as! [String: Any]

/// The property names a schema declares, through `$ref` and `allOf`.
func declaredProperties(_ schema: Any) -> Set<String> {
    guard let object = schema as? [String: Any] else { return [] }
    if let reference = object["$ref"] as? String {
        let name = String(reference.split(separator: "/").last!)
        return declaredProperties(schemas[name] as Any)
    }
    var names = Set((object["properties"] as? [String: Any] ?? [:]).keys)
    for part in object["allOf"] as? [Any] ?? [] { names.formUnion(declaredProperties(part)) }
    return names
}

var mergedDiscriminators = 0

func mergingUnfoundDiscriminators(_ value: Any) -> Any {
    if var object = value as? [String: Any] {
        if let discriminator = object["discriminator"] as? [String: Any],
           let property = discriminator["propertyName"] as? String,
           let branches = object["oneOf"] as? [Any],
           !branches.contains(where: { declaredProperties($0).contains(property) }) {
            object.removeValue(forKey: "discriminator")
            object.removeValue(forKey: "oneOf")
            object["allOf"] = branches
            mergedDiscriminators += 1
        }
        return object.mapValues(mergingUnfoundDiscriminators)
    }
    if let array = value as? [Any] { return array.map(mergingUnfoundDiscriminators) }
    return value
}

schemas = mergingUnfoundDiscriminators(schemas) as! [String: Any]

var nullableToOne = Set<String>()
for value in (document["paths"] as! [String: Any]).values {
    guard let get = (value as? [String: Any])?["get"] as? [String: Any],
          (get["operationId"] as? String)?.hasSuffix("_getToOneRelated") == true,
          let ok = (get["responses"] as? [String: Any])?["200"] as? [String: Any],
          let reference = ((ok["content"] as? [String: Any])?["application/json"] as? [String: Any])?["schema"] as? [String: Any],
          let name = (reference["$ref"] as? String)?.split(separator: "/").last.map(String.init),
          var schema = schemas[name] as? [String: Any],
          var properties = schema["properties"] as? [String: Any],
          var data = properties["data"] as? [String: Any]
    else { continue }
    data["nullable"] = true
    properties["data"] = data
    schema["properties"] = properties
    schema["required"] = (schema["required"] as? [String] ?? []).filter { $0 != "data" }
    schemas[name] = schema
    nullableToOne.insert(name)
}
components["schemas"] = schemas
document["components"] = components

let cursor: [String: Any] = [
    "name": "cursor",
    "in": "query",
    "description": "the page to return, from the previous page's links.next",
    "schema": ["type": "string"],
    "required": false,
]

var paths = document["paths"] as! [String: Any]
var paged = 0
for (path, value) in paths {
    var item = value as! [String: Any]
    guard var get = item["get"] as? [String: Any],
          var parameters = get["parameters"] as? [[String: Any]],
          parameters.contains(where: { $0["name"] as? String == "limit" }),
          !parameters.contains(where: { $0["name"] as? String == "cursor" })
    else { continue }
    parameters.append(cursor)
    get["parameters"] = parameters
    item["get"] = get
    paths[path] = item
    paged += 1
}
document["paths"] = paths

let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
try data.write(to: destination)
let version = (document["info"] as? [String: Any])?["version"] as? String ?? "?"
print("""
    Wrote \(destination.path): App Store Connect API \(version).
    Removed \(removedEnums) enums and \(removedConstraints) constraint-only compositions, \
    merged \(mergedDiscriminators) discriminators that named a missing property, \
    made data optional in \(nullableToOne.count) to-one responses, \
    added cursor to \(paged) GET operations.
    """)
