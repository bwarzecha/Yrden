# JSONValue Test Strategy

> Test plan for the JSONValue type. Focus: our code, not Apple's JSONDecoder.

---

## Implementation Approach: Incremental with Tests First

We build JSONValue incrementally. Each feature is fully tested before adding the next.

### Phase 1: Primitives (null, bool, int, double, string)

```
Step 1.1: null
  - Add: case null
  - Add: Custom Codable for null
  - Test: encode/decode null

Step 1.2: bool
  - Add: case bool(Bool)
  - Add: Codable for bool
  - Add: boolValue accessor
  - Add: ExpressibleByBooleanLiteral
  - Test: encode/decode true, false
  - Test: boolValue returns value or nil
  - Test: literal assignment

Step 1.3: int
  - Add: case int(Int)
  - Add: Codable for int
  - Add: intValue accessor
  - Add: ExpressibleByIntegerLiteral
  - Test: encode/decode positive, negative, zero, large
  - Test: intValue returns value or nil
  - Test: literal assignment

Step 1.4: double
  - Add: case double(Double)
  - Add: Codable for double
  - Add: doubleValue accessor
  - Add: ExpressibleByFloatLiteral
  - Test: encode/decode decimal, scientific notation
  - Test: doubleValue returns value or nil
  - Test: literal assignment
  - Test: int vs double distinction preserved

Step 1.5: string
  - Add: case string(String)
  - Add: Codable for string
  - Add: stringValue accessor
  - Add: ExpressibleByStringLiteral
  - Test: encode/decode normal, empty, unicode, escaped chars
  - Test: stringValue returns value or nil
  - Test: literal assignment
```

### Phase 2: Object (dictionary)

```
Step 2.1: Basic object
  - Add: indirect case object([String: JSONValue])
  - Add: Codable for object
  - Add: objectValue accessor
  - Add: ExpressibleByDictionaryLiteral
  - Test: encode/decode empty object, simple object
  - Test: objectValue returns value or nil
  - Test: literal assignment

Step 2.2: Object subscript
  - Add: subscript(key: String) -> JSONValue?
  - Test: existing key returns value
  - Test: missing key returns nil
  - Test: subscript on non-object returns nil

Step 2.3: Nested objects
  - Test: encode/decode nested objects
  - Test: chained subscript access: json["a"]?["b"]?["c"]
```

### Phase 3: Array

```
Step 3.1: Basic array
  - Add: indirect case array([JSONValue])
  - Add: Codable for array
  - Add: arrayValue accessor
  - Add: ExpressibleByArrayLiteral
  - Test: encode/decode empty array, homogeneous array
  - Test: arrayValue returns value or nil
  - Test: literal assignment

Step 3.2: Array subscript
  - Add: subscript(index: Int) -> JSONValue?
  - Test: valid index returns value
  - Test: out of bounds returns nil
  - Test: subscript on non-array returns nil

Step 3.3: Heterogeneous arrays
  - Test: encode/decode mixed type arrays
  - Test: arrays containing objects
  - Test: objects containing arrays
```

### Phase 4: Equatable & Hashable

```
Step 4.1: Equatable
  - Verify synthesized Equatable works
  - Test: same values equal
  - Test: different values not equal
  - Test: nested structures compare correctly
  - Test: object equality is key-order independent
  - Test: array equality is order dependent

Step 4.2: Hashable
  - Verify synthesized Hashable works
  - Test: can use as dictionary key
  - Test: can add to Set
```

### Phase 5: End-to-End

```
Step 5.1: JSON Schema scenarios
  - Test: build schema with literals → encode → verify JSON string → decode → access

Step 5.2: Tool arguments scenarios
  - Test: parse raw JSON string → extract typed values → handle missing keys

Step 5.3: Structured output scenarios
  - Test: full cycle schema + response simulation
```

### Why This Order?

1. **Primitives first** - Foundation for everything else
2. **Object before array** - More common in schemas, tests dict subscript first
3. **Each step is testable** - Never add untested code
4. **Complexity builds gradually** - Nested structures come after simple ones work

---

## What We're Testing

| Layer | Owner | Test? |
|-------|-------|-------|
| JSON parsing (bytes → tokens) | Apple's JSONDecoder | No |
| JSON semantics (valid vs invalid) | Apple's JSONDecoder | No |
| **Codable implementation** | Us | **Yes** |
| **Enum representation** | Us | **Yes** |
| **Accessors & subscripts** | Us | **Yes** |
| **Literal expressibility** | Us | **Yes** |

---

## Test Categories

### 1. Codable Round-Trip

**Purpose**: Verify encode → decode produces identical value.

```
test_roundTrip_null
test_roundTrip_bool_true
test_roundTrip_bool_false
test_roundTrip_int_positive
test_roundTrip_int_negative
test_roundTrip_int_zero
test_roundTrip_double
test_roundTrip_string
test_roundTrip_string_empty
test_roundTrip_string_unicode
test_roundTrip_array_empty
test_roundTrip_array_homogeneous
test_roundTrip_array_heterogeneous
test_roundTrip_object_empty
test_roundTrip_object_simple
test_roundTrip_object_nested
```

**Pattern**:
```swift
func test_roundTrip_<case>() throws {
    let original: JSONValue = <value>
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    XCTAssertEqual(original, decoded)
}
```

### 2. Encoding Format

**Purpose**: Verify we encode as real JSON, not Swift's synthesized enum format.

```
test_encode_null_producesNull
test_encode_bool_producesBool
test_encode_int_producesNumber
test_encode_double_producesNumber
test_encode_string_producesString
test_encode_array_producesArray
test_encode_object_producesObject
```

**Pattern**:
```swift
func test_encode_<case>() throws {
    let value: JSONValue = <value>
    let data = try JSONEncoder().encode(value)
    let json = String(data: data, encoding: .utf8)!
    XCTAssertEqual(json, "<expected_json_string>")
}
```

**Critical**: These tests catch if we accidentally use synthesized Codable (which produces `{"string":{"_0":"hello"}}` instead of `"hello"`).

### 3. Decoding From Raw JSON

**Purpose**: Verify we can decode JSON strings that come from external sources (LLM responses, config files).

```
test_decode_null
test_decode_bool
test_decode_int
test_decode_double
test_decode_string
test_decode_array
test_decode_object
test_decode_nested
```

**Pattern**:
```swift
func test_decode_<case>() throws {
    let json = "<raw_json_string>"
    let data = json.data(using: .utf8)!
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    XCTAssertEqual(value, <expected_JSONValue>)
}
```

### 4. Accessor Methods

**Purpose**: Verify type-safe accessors return correct values or nil.

```
test_stringValue_returnsString
test_stringValue_returnsNil_whenInt
test_intValue_returnsInt
test_intValue_returnsNil_whenString
test_doubleValue_returnsDouble
test_boolValue_returnsBool
test_arrayValue_returnsArray
test_objectValue_returnsObject
```

**Pattern**:
```swift
func test_<accessor>_returnsCorrectType() {
    let value: JSONValue = <matching_type>
    XCTAssertEqual(value.<accessor>, <expected>)
}

func test_<accessor>_returnsNil_when<WrongType>() {
    let value: JSONValue = <wrong_type>
    XCTAssertNil(value.<accessor>)
}
```

### 5. Subscript Access

**Purpose**: Verify dictionary and array subscript access.

```
test_subscript_object_existingKey
test_subscript_object_missingKey
test_subscript_object_onNonObject
test_subscript_array_validIndex
test_subscript_array_outOfBounds
test_subscript_array_onNonArray
test_subscript_chained
```

**Pattern**:
```swift
func test_subscript_chained() {
    let json: JSONValue = [
        "user": [
            "profile": [
                "name": "Alice"
            ]
        ]
    ]
    XCTAssertEqual(json["user"]?["profile"]?["name"]?.stringValue, "Alice")
    XCTAssertNil(json["user"]?["missing"]?["name"])
}
```

### 6. Literal Expressibility

**Purpose**: Verify we can construct JSONValue using Swift literals.

```
test_literal_nil
test_literal_bool
test_literal_int
test_literal_double
test_literal_string
test_literal_array
test_literal_dictionary
test_literal_nested
```

**Pattern**:
```swift
func test_literal_nested() {
    let json: JSONValue = [
        "name": "Alice",
        "age": 30,
        "active": true,
        "tags": ["admin", "user"]
    ]

    XCTAssertEqual(json["name"]?.stringValue, "Alice")
    XCTAssertEqual(json["age"]?.intValue, 30)
    XCTAssertEqual(json["active"]?.boolValue, true)
    XCTAssertEqual(json["tags"]?[0]?.stringValue, "admin")
}
```

### 7. Equatable

**Purpose**: Verify equality works correctly, especially for nested structures.

```
test_equatable_sameValues
test_equatable_differentValues
test_equatable_nestedObjects
test_equatable_orderIndependent_objects
test_equatable_orderDependent_arrays
```

**Key case**: Object equality should be order-independent (dictionaries), array equality should be order-dependent.

### 8. End-to-End: Real-World Scenarios

**Purpose**: Verify JSONValue works correctly through all layers for actual use cases. These tests simulate what happens when we send schemas to LLM providers and receive responses.

```
test_e2e_jsonSchema_encodeAndVerify
test_e2e_toolArguments_decodeFromString
test_e2e_structuredOutput_fullCycle
test_e2e_nestedSchema_matchesExpectedJSON
```

**Pattern**:
```swift
func test_e2e_jsonSchema_encodeAndVerify() throws {
    // 1. Build a schema like we would for a tool
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "User name"],
            "age": ["type": "integer", "description": "Age in years"]
        ],
        "required": ["name", "age"],
        "additionalProperties": false
    ]

    // 2. Encode to JSON (what we'd send to provider)
    let data = try JSONEncoder().encode(schema)
    let jsonString = String(data: data, encoding: .utf8)!

    // 3. Verify the JSON matches expected format
    //    (This is what Anthropic/OpenAI will receive)
    XCTAssertTrue(jsonString.contains("\"type\":\"object\""))
    XCTAssertTrue(jsonString.contains("\"additionalProperties\":false"))

    // 4. Decode back and verify round-trip
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    XCTAssertEqual(schema, decoded)

    // 5. Verify we can access nested values
    XCTAssertEqual(decoded["properties"]?["name"]?["type"]?.stringValue, "string")
}

func test_e2e_toolArguments_decodeFromString() throws {
    // Simulate receiving tool arguments from LLM (raw JSON string)
    let llmResponse = """
    {"query": "weather in London", "limit": 5, "include_forecast": true}
    """

    // 1. Parse the raw string
    let data = llmResponse.data(using: .utf8)!
    let args = try JSONDecoder().decode(JSONValue.self, from: data)

    // 2. Verify we can extract typed values
    XCTAssertEqual(args["query"]?.stringValue, "weather in London")
    XCTAssertEqual(args["limit"]?.intValue, 5)
    XCTAssertEqual(args["include_forecast"]?.boolValue, true)

    // 3. Verify missing keys return nil (not crash)
    XCTAssertNil(args["missing"]?.stringValue)
}

func test_e2e_structuredOutput_fullCycle() throws {
    // 1. Define expected output schema
    let outputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "confidence": ["type": "number"],
            "tags": ["type": "array", "items": ["type": "string"]]
        ],
        "required": ["summary", "confidence", "tags"]
    ]

    // 2. Simulate LLM response matching that schema
    let llmOutput = """
    {"summary": "Analysis complete", "confidence": 0.95, "tags": ["urgent", "reviewed"]}
    """

    // 3. Parse response
    let data = llmOutput.data(using: .utf8)!
    let result = try JSONDecoder().decode(JSONValue.self, from: data)

    // 4. Verify structure matches what schema describes
    XCTAssertEqual(result["summary"]?.stringValue, "Analysis complete")
    XCTAssertEqual(result["confidence"]?.doubleValue, 0.95)
    XCTAssertEqual(result["tags"]?.arrayValue?.count, 2)
    XCTAssertEqual(result["tags"]?[0]?.stringValue, "urgent")
}
```

**Why these matter**: Unit tests verify parts work. E2E tests verify the whole flow works - from schema construction through encoding, transmission simulation, decoding, and value extraction.

---

## Test File Structure

Split tests into multiple files from the start - one file per phase/category.

```
Tests/YrdenTests/
└── JSONValue/
    ├── JSONValuePrimitiveTests.swift   # Phase 1: null, bool, int, double, string
    ├── JSONValueObjectTests.swift       # Phase 2: object, subscript, nested
    ├── JSONValueArrayTests.swift        # Phase 3: array, subscript, mixed
    ├── JSONValueEqualityTests.swift     # Phase 4: Equatable, Hashable
    └── JSONValueE2ETests.swift          # Phase 5: end-to-end scenarios
```

**Why separate files:**
- Run individual test files during development (`swift test --filter JSONValuePrimitiveTests`)
- Easy to see what's tested for each feature
- Keeps files small and focused
- Parallel test execution

---

## Naming Convention

```
test_<category>_<scenario>
test_<category>_<scenario>_when<Condition>
```

Examples:
- `test_roundTrip_object_nested`
- `test_encode_string_producesString`
- `test_subscript_object_returnsNil_whenKeyMissing`

---

## What We're NOT Testing

1. **JSON parsing edge cases** (malformed JSON, unicode edge cases) - Apple's responsibility
2. **Performance** - premature optimization, revisit if needed
3. **Thread safety** - JSONValue is a value type, inherently safe
4. **Sendable compliance** - compiler enforces this

---

## Test Data

Use simple, readable values. No need for realistic data - we're testing mechanics.

```swift
// Good: clear what's being tested
let json: JSONValue = ["key": "value"]

// Avoid: adds noise, doesn't improve coverage
let json: JSONValue = [
    "firstName": "Alice",
    "lastName": "Smith",
    "email": "alice@example.com",
    // ...
]
```

---

## Success Criteria

- [ ] All 8 categories have tests
- [ ] Each test tests ONE thing
- [ ] Test names clearly describe what's being tested
- [ ] No test relies on another test's state
- [ ] E2E tests cover real-world scenarios (schema, tool args, structured output)
- [ ] **Comprehensive coverage** - test every edge case, not a fixed number
- [ ] Tests run in < 1 second total

## Philosophy: Test Extensively

The test counts (~45) are rough estimates, not limits. The goal is **zero production bugs** from JSONValue.

Test extensively:
- Empty values (empty string, empty array, empty object)
- Boundary values (Int.max, Int.min, very long strings)
- Unicode (emoji, RTL, special characters)
- Null in various positions (array element, object value)
- Deep nesting (5+ levels)
- Large structures (100+ keys, 100+ array elements)

If you think "this might break in production" → write a test for it.

---

## Assertion Quality

Every test must have **clear, unambiguous assertions** that fail for meaningful reasons.

### Good Assertions

```swift
// Clear: tests exactly one thing, obvious why it would fail
XCTAssertEqual(json["name"]?.stringValue, "Alice")
XCTAssertNil(json["missing"])
XCTAssertEqual(decoded, original)  // round-trip equality
```

### Bad Assertions

```swift
// Ambiguous: could fail for many reasons
XCTAssertTrue(jsonString.contains("name"))  // What if "name" appears elsewhere?
XCTAssertNotNil(result)  // Doesn't verify the VALUE is correct

// Flaky: depends on implementation details that could change
XCTAssertEqual(jsonString, "{\"a\":1,\"b\":2}")  // Key order not guaranteed!

// Meaningless: doesn't actually test behavior
XCTAssertTrue(true)
```

### Rules

1. **Assert the exact value**, not just existence
   - Bad: `XCTAssertNotNil(json["key"])`
   - Good: `XCTAssertEqual(json["key"]?.stringValue, "expected")`

2. **Don't assert on JSON string order** - dictionaries have no guaranteed key order
   - Bad: `XCTAssertEqual(jsonString, "{\"a\":1,\"b\":2}")`
   - Good: Decode back and compare values, or use `contains` for specific fields

3. **One logical assertion per test** - if a test fails, it should be obvious what broke
   - Exception: setup assertions (verifying preconditions) are fine

4. **Use descriptive failure messages** when the assertion isn't self-explanatory
   ```swift
   XCTAssertEqual(result.count, 3, "Expected 3 items after filtering")
   ```

5. **No random/timing-dependent assertions** - tests must be deterministic
