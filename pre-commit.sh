#!/bin/bash

echo "🔍 Running swift-format check..."

# Run swift-format in lint mode
swift-format lint -r SQLNotebook/

if [ $? -ne 0 ]; then
  echo ""
  echo "❌ Code formatting check failed!"
  echo ""
  echo "Please run the following command to fix formatting:"
  echo "  swift-format -i -r SQLNotebook/"
  echo ""
  exit 1
fi

echo "✅ Code formatting check passed!"
exit 0
