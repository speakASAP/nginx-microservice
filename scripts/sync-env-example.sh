#!/bin/bash

# Script to sync .env file to .env.example by extracting only variable names (keys) without values
# Usage: ./sync-env-example.sh <path-to-.env-file>
# This script is called by watch-env-sync.sh to automatically update .env.example when .env changes

set -e

# Check if argument is provided
if [ $# -eq 0 ]; then
    echo "Error: .env file path is required"
    echo "Usage: $0 <path-to-.env-file>"
    exit 1
fi

ENV_FILE="$1"

# Check if .env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found: $ENV_FILE"
    exit 1
fi

# Extract directory path from .env file path
ENV_DIR="$(cd "$(dirname "$ENV_FILE")" && pwd)"
ENV_EXAMPLE_FILE="${ENV_DIR}/.env.example"

# Create temporary file for output
TEMP_FILE=$(mktemp)

# Process .env file line by line
while IFS= read -r line || [ -n "$line" ]; do
    # Trim leading/trailing whitespace
    trimmed_line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # If empty line, preserve it
    if [ -z "$trimmed_line" ]; then
        echo "" >> "$TEMP_FILE"
        continue
    fi
    
    # If comment line (starts with #), preserve it
    if [[ "$trimmed_line" =~ ^# ]]; then
        echo "$line" >> "$TEMP_FILE"
        continue
    fi
    
    # If line contains =, extract key
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]* ]]; then
        # Extract variable name (key)
        key="${BASH_REMATCH[1]}"
        
        # Extract everything after the = sign
        value_part="${line#*=}"
        # Remove leading whitespace from value part
        value_part=$(echo "$value_part" | sed 's/^[[:space:]]*//')
        
        # Check if value starts with a quote (single or double)
        if [[ "$value_part" =~ ^[\'\"] ]]; then
            # Value is quoted - find the matching closing quote
            quote_char="${value_part:0:1}"
            quote_pos=0
            escaped=false
            found_closing=false
            
            # Find the matching closing quote, handling escaped quotes
            for ((i=1; i<${#value_part}; i++)); do
                char="${value_part:$i:1}"
                if [ "$escaped" = true ]; then
                    escaped=false
                    continue
                fi
                if [ "$char" = "\\" ]; then
                    escaped=true
                    continue
                fi
                if [ "$char" = "$quote_char" ]; then
                    quote_pos=$i
                    found_closing=true
                    break
                fi
            done
            
            if [ "$found_closing" = true ]; then
                # Check for comment after the closing quote
                after_quote="${value_part:$((quote_pos+1))}"
                # Remove leading whitespace
                after_quote=$(echo "$after_quote" | sed 's/^[[:space:]]*//')
                if [[ "$after_quote" =~ ^#(.*)$ ]]; then
                    comment="${BASH_REMATCH[1]}"
                    echo "${key}= #${comment}" >> "$TEMP_FILE"
                else
                    echo "${key}=" >> "$TEMP_FILE"
                fi
            else
                # No closing quote found, treat as unquoted
                if [[ "$value_part" =~ ^[^#]*#(.*)$ ]]; then
                    comment="${BASH_REMATCH[1]}"
                    echo "${key}= #${comment}" >> "$TEMP_FILE"
                else
                    echo "${key}=" >> "$TEMP_FILE"
                fi
            fi
        else
            # Value is not quoted - check for comment (first # that's not inside quotes)
            if [[ "$value_part" =~ ^[^#]*#(.*)$ ]]; then
                comment="${BASH_REMATCH[1]}"
                echo "${key}= #${comment}" >> "$TEMP_FILE"
            else
                echo "${key}=" >> "$TEMP_FILE"
            fi
        fi
    else
        # Invalid format, preserve as-is (might be continuation or special case)
        echo "$line" >> "$TEMP_FILE"
    fi
done < "$ENV_FILE"

# Move temporary file to .env.example (atomic operation)
mv "$TEMP_FILE" "$ENV_EXAMPLE_FILE"

echo "✅ Synced $ENV_FILE to $ENV_EXAMPLE_FILE"

