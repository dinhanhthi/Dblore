#!/bin/bash
# Diagnostic script to check if results are being saved in .dblore files

echo "🔍 Dblore Result Saving Diagnostic"
echo "========================================"
echo ""

# Check UserDefaults for includeResultsOnSave setting
echo "1️⃣ Checking app settings..."
defaults read ace.thi.Dblore app.settings.includeResultsOnSave 2>/dev/null
INCLUDE_RESULTS=$?

if [ $INCLUDE_RESULTS -eq 0 ]; then
    SETTING_VALUE=$(defaults read ace.thi.Dblore app.settings.includeResultsOnSave)
    if [ "$SETTING_VALUE" == "1" ]; then
        echo "✅ includeResultsOnSave = TRUE (results should be saved)"
    else
        echo "❌ includeResultsOnSave = FALSE (results will NOT be saved)"
        echo "   👉 Fix: Open Settings sidebar and enable 'Include Results When Saving'"
    fi
else
    echo "⚠️  Setting not found (using default: TRUE)"
fi

echo ""
echo "2️⃣ Looking for recent .dblore files..."
find ~/Documents -name "*.dblore" -type f -mtime -1 2>/dev/null | head -5 | while read file; do
    echo ""
    echo "📄 File: $file"
    echo "   Size: $(stat -f%z "$file") bytes"
    
    # Check if file contains "result" field
    if grep -q '"result"' "$file"; then
        RESULT_COUNT=$(grep -o '"result"' "$file" | wc -l)
        echo "   ✅ Contains $RESULT_COUNT result(s)"
        
        # Show first result snippet
        echo "   Sample:"
        cat "$file" | python3 -m json.tool 2>/dev/null | grep -A 5 '"result"' | head -10 | sed 's/^/      /'
    else
        echo "   ❌ No results found in file"
        echo "   Possible causes:"
        echo "      - Setting was disabled when saved"
        echo "      - No queries were executed before saving"
        echo "      - File corruption"
    fi
done

if [ ! -f ~/Documents/*.dblore ]; then
    echo "   No .dblore files found in ~/Documents"
    echo "   Please specify a file path:"
    echo "   Usage: $0 /path/to/your/file.dblore"
fi

echo ""
echo "3️⃣ Testing result serialization..."
swift /tmp/test_result_save.swift >/dev/null 2>&1
if grep -q '"result"' /tmp/test_notebook.dblore; then
    echo "✅ Result serialization is working correctly"
else
    echo "❌ Result serialization test failed"
fi

echo ""
echo "========================================"
echo "💡 Quick Fixes:"
echo "   1. Open Dblore"
echo "   2. Click Settings icon (⚙️) in right sidebar"
echo "   3. Enable 'Include Results When Saving' toggle"
echo "   4. Save the file again (Cmd+S)"
echo ""
