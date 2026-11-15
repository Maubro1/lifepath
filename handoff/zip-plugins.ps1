# Zips every installed plugin and skill into handoff/private/plugins/ (git-ignored: prefskill holds personal preferences).
$out = Join-Path $PSScriptRoot "private\plugins"
New-Item -ItemType Directory -Force "$out\installed", "$out\downloads-originals" | Out-Null
Get-ChildItem "$env:APPDATA\Claude\rpm\*\*\plugin_*" -Directory | ForEach-Object {
  $name = (Get-Content "$($_.FullName)\.claude-plugin\plugin.json" -Raw | ConvertFrom-Json).name
  Compress-Archive -Path "$($_.FullName)\*" -DestinationPath "$out\installed\$name.zip" -Force
}
$cli = @{
  'superpowers-cli'  = "$env:USERPROFILE\.claude\plugins\marketplaces\local-desktop-app-uploads\superpowers"
  'page-check-cli'   = "$env:USERPROFILE\.claude\plugins\marketplaces\local-desktop-app-uploads\page-check"
  'diagram-design'   = (Get-ChildItem "$env:USERPROFILE\.claude\plugins\cache\diagram-design\diagram-design" -Directory | Select-Object -Last 1).FullName
  'anthropic-skills' = (Get-ChildItem "$env:APPDATA\Claude\local-agent-mode-sessions\skills-plugin\*\*\skills\llm-council" -Directory | Select-Object -Last 1).Parent.Parent.FullName
}
foreach ($k in $cli.Keys) { if ($cli[$k] -and (Test-Path $cli[$k])) { Compress-Archive -Path "$($cli[$k])\*" -DestinationPath "$out\installed\$k.zip" -Force } else { "missing: $k" } }
$dl = "$env:USERPROFILE\Downloads"
'claude-skills-main','deepread','enso-seo','enso-SEO-GEO-main','impeccable','litreview','logic-reasoning','logic-reasoning-skills-main','reflect','superpowers-main','claude-code-kit-1.35.1' |
  ForEach-Object { if (Test-Path "$dl\$_.zip") { Copy-Item "$dl\$_.zip" "$out\downloads-originals\" -Force } }
if (Test-Path "$dl\plugins") { Copy-Item "$dl\plugins\*.zip" "$out\downloads-originals\" -Force }
"plugins zipped into $out"
