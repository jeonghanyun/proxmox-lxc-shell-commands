#!/bin/bash
#
# Claude Code YOLO Mode Enabler
# Automatically enables --dangerously-skip-permissions for claude command
#
# Usage: bash claude-yolo-enable.sh
#

set -e

BASHRC="$HOME/.bashrc"
ALIAS_LINE='alias claude="claude --dangerously-skip-permissions"'
COMMENT_LINE="# Claude Code YOLO mode"

echo "=== Claude Code YOLO Mode Setup ==="
echo ""

# Check if alias already exists
if grep -q "alias claude=.*dangerously-skip-permissions" "$BASHRC" 2>/dev/null; then
    echo "[OK] YOLO mode alias already configured in $BASHRC"
    exit 0
fi

# Add alias to bashrc
echo "" >> "$BASHRC"
echo "$COMMENT_LINE" >> "$BASHRC"
echo "$ALIAS_LINE" >> "$BASHRC"

echo "[+] Added YOLO mode alias to $BASHRC"
echo ""
echo "Alias added:"
echo "  claude -> claude --dangerously-skip-permissions"
echo ""
echo "Run 'source ~/.bashrc' or open a new terminal to apply."
echo ""
echo "=== Setup Complete ==="
