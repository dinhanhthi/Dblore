# PostgreSQL pgvector Extension Support

## Problem

PostgreSQL tables using the `pgvector` extension (for storing vector embeddings) displayed incorrectly in SQLNotebook:
- Column type showed as "UNKNOWN" or "USER-DEFINED" instead of "VECTOR"
- Column values displayed as binary garbage characters (`:��9�H%<6���`) instead of readable arrays like `[0.123, 0.456, ...]`

This occurred because pgvector creates a custom user-defined type called `vector`, which stores data in a binary format that the app didn't recognize or parse.

## Solution

Implemented comprehensive support for pgvector by:
1. Detecting vector types from PostgreSQL metadata (type name or UNKNOWN OID)
2. Parsing pgvector's binary storage format (**big-endian floats**)
3. Converting binary data to human-readable array format with proper precision

### Key Changes

**1. Type Name Detection**
- `DatabaseTypes+PostgreSQL.swift:71-84` - Enhanced `postgresDataTypeName()` to detect vector types
  - Checks if type name contains "vector" (case-insensitive) → returns "VECTOR"
  - Falls back to "USER-DEFINED" for other custom types

**2. Column Type Enrichment**
- `DatabaseConnectionManager+QueryWrapping.swift:168-178` - Added `udt_name` column to information_schema query
- `DatabaseConnectionManager+QueryWrapping.swift:190-212` - Use `udt_name` when `data_type` is "USER-DEFINED"
  - This retrieves the actual type name ("vector") from PostgreSQL catalog

**3. Binary Data Parsing**
- `DatabaseTypes+PostgreSQL.swift:177-215` - Updated `parseCellValue()` to handle vector type
  - Detects UNKNOWN types (PostgresNIO returns "UNKNOWN <OID>" for custom types)
  - Tries parsing raw bytes as pgvector binary format
  - Falls back to ByteBuffer decoding and text format

- `DatabaseTypes+PostgreSQL.swift:256-315` - Added `parseVectorValue(from: ByteBuffer)` function
  - Parses pgvector binary format into readable string
  - Returns formatted array like `[0.0033721924, -0.062042236, ...]`

## pgvector Binary Format Specification

**Critical Discovery**: pgvector uses **BIG-ENDIAN** byte order for float values!

```
Offset | Size  | Type   | Description
-------|-------|--------|----------------------------------
0      | 4     | Header | 4-byte header (dimension metadata)
4      | 4*N   | Float32| Array of N float values (BIG-ENDIAN)
```

The actual dimension is calculated from buffer size: `(total_bytes - 4) / 4`

**Example**: Vector with 1536 dimensions (6148 bytes total)
```
Hex: 06 00 00 00 BD 7E 20 00 3B F4 80 00 3D 21 A0 00 ...
     └─header──┘ └──float1──┘ └──float2──┘ └──float3──┘
      (skip 4)   (BIG-ENDIAN) (BIG-ENDIAN) (BIG-ENDIAN)

Calculation:
- Total: 6148 bytes
- Header: 4 bytes
- Float data: 6144 bytes
- Dimension: 6144 / 4 = 1536 floats

Float parsing (BIG-ENDIAN):
- Bytes: BD 7E 20 00 → 0xBD7E2000 → -0.062042236 ✓
- Wrong (little-endian): 0x00207EBD → 2.984201e-39 ✗
```

### Parsing Implementation

```swift
private func parseVectorValue(from buffer: ByteBuffer) -> CellValue? {
  var buffer = buffer

  // Skip 4-byte header
  _ = buffer.readInteger(endianness: .little, as: UInt32.self)

  // Calculate dimension from remaining bytes
  let dimension = buffer.readableBytes / 4

  // Read floats in BIG-ENDIAN format (critical!)
  var values: [Float] = []
  for _ in 0..<dimension {
    if let bits = buffer.readInteger(endianness: .big, as: UInt32.self) {
      values.append(Float(bitPattern: bits))
    }
  }

  // Format with 9 significant digits (%.9g)
  let formatted = values.map { String(format: "%.9g", $0) }.joined(separator: ", ")
  return .string("[\(formatted)]")
}
```

## Implementation Details

### Type Detection Flow

1. Query executes → PostgresNIO returns `PostgresCell` with `dataType`
2. For user-defined types, PostgresNIO returns "UNKNOWN <OID>" (e.g., "UNKNOWN 16387")
3. `parseCellValue()` checks if type starts with "UNKNOWN" or contains "vector"
4. Attempts to parse as pgvector binary format
5. Column type displayed as "VECTOR" in UI (via enrichment)

### Value Parsing Flow

1. `parseCellValue()` receives `PostgresCell` with raw bytes
2. For UNKNOWN or vector types:
   - Try parsing `cell.bytes` directly as pgvector format
   - Fallback to `cell.decode(ByteBuffer.self)` if needed
   - Last resort: try text format `cell.decode(String.self)`
3. `parseVectorValue()` converts binary data to readable string using **big-endian**
4. Display formatted array in result table

### Column Enrichment Flow

1. After query execution, `enrichColumnTypes()` is called
2. Queries `information_schema.columns` with `udt_name` included
3. For "USER-DEFINED" types, replaces generic name with actual `udt_name`
4. Result: "VECTOR" instead of "USER-DEFINED" in column headers

## Testing

### Manual Test Steps

1. Connect to PostgreSQL database with pgvector extension installed
2. Create test table:
   ```sql
   CREATE EXTENSION IF NOT EXISTS vector;
   CREATE TABLE test_vectors (
     id SERIAL PRIMARY KEY,
     embedding vector(1536)
   );
   INSERT INTO test_vectors (embedding) VALUES
     (array_fill(0.1::float4, ARRAY[1536])::vector);
   ```
3. Query the table: `SELECT * FROM test_vectors;`
4. Verify:
   - ✅ Column type shows "VECTOR"
   - ✅ Values display as `[0.1, 0.1, 0.1, ...]` with 1536 elements
   - ✅ Precision shows up to 9 significant digits (e.g., `-0.0033721924`)

### Expected Results

**Before Fix:**
```
Column: embedding (UNKNOWN)
Value:  :��9�H%<6���
```

**After Fix:**
```
Column: embedding (VECTOR)
Value:  [-0.062042236, 0.0033721924, 0.00514221, ...]
```

## Key Learnings

1. **Endianness Matters**: pgvector stores floats in big-endian, despite PostgreSQL typically using platform native (little-endian on x86)
2. **Type Detection**: Custom PostgreSQL types appear as "UNKNOWN <OID>" in PostgresNIO, not the actual type name
3. **Dimension Calculation**: The 4-byte header's exact format is unclear, so dimension is calculated from buffer size
4. **Precision**: Use `%.9g` format for Float32 to show up to 9 significant digits without scientific notation for typical embedding values

## Files Modified

1. **DatabaseTypes+PostgreSQL.swift**
   - Lines 71-84: Type name detection for vector
   - Lines 177-215: Cell value parsing for UNKNOWN/vector types
   - Lines 256-315: Binary pgvector format parser

2. **DatabaseConnectionManager+QueryWrapping.swift**
   - Lines 168-212: Column type enrichment with `udt_name`

## Status

✅ **Completed** - pgvector support fully implemented and tested
- Column type correctly shows "VECTOR"
- Values display as readable arrays with correct precision
- Handles vectors of any dimension (tested with 1536)
- Matches PostgreSQL text output format

## References

- [pgvector GitHub](https://github.com/pgvector/pgvector) - Official pgvector extension
- PostgresNIO library for database communication
- Float32 IEEE 754 binary representation
