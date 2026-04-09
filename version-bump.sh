#!/bin/bash
# Auto-increment patch version in build.sh
# Usage: ./version-bump.sh [major|minor|patch]

BUMP_TYPE="${1:-patch}"
CURRENT=$(grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' build.sh | head -1)

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case "$BUMP_TYPE" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
esac

NEW="$MAJOR.$MINOR.$PATCH"
sed -i '' "s/$CURRENT/$NEW/" build.sh
echo "$CURRENT -> $NEW"
