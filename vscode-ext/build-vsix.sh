#!/usr/bin/env bash
# Packages the extension without vsce: a vsix is only a zip with a manifest.
set -euo pipefail
cd "$(dirname "$0")"
out="$PWD/../claude-waiting-focus.vsix"
ver="$(jq -r .version package.json)"
tmp="$(mktemp -d)"
mkdir "$tmp/extension"
cp package.json extension.js "$tmp/extension/"
cat > "$tmp/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="claude-waiting-focus" Version="$ver" Publisher="nishanth"/>
    <DisplayName>Claude Waiting: focus terminal</DisplayName>
    <Description xml:space="preserve">Lets the Claude Waiting widget bring a terminal tab to the front by its tty.</Description>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui,workspace"/>
    </Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
</PackageManifest>
XML
cat > "$tmp/[Content_Types].xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json"/>
  <Default Extension="js" ContentType="application/javascript"/>
  <Default Extension="vsixmanifest" ContentType="text/xml"/>
</Types>
XML
rm -f "$out"
(cd "$tmp" && zip -qr "$out" .)
rm -rf "$tmp"
echo "built $out"
