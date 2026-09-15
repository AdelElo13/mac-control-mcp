# S3 C2 — Finder floating-header live check

## Voorwaarden

Voer dit uit vanuit deze worktree met de gebouwde debugbinary. Gebruik de Finder-lijstweergave uit de review: pid 742, Size op (1444.5,105), Kind op (1550.5,105). Controleer de bestaande venstergeometrie met een read-only probe als de layout mogelijk veranderd is; verplaats of wijzig geen gebruikersvenster om de fixture passend te maken.

## Exacte probe — acht runs per kolomkop

```sh
SCRATCH=/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad
PROBE_MAX=300000 python3 "$SCRATCH/probe.py" .build/debug/mac-control-mcp '[
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1444.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1550.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1444.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1550.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1444.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1550.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1444.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1550.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1444.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1550.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1444.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1550.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1444.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1550.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1444.5,
      "y": 105
    }
  ],
  [
    "element_at_point",
    {
      "pid": 742,
      "x": 1550.5,
      "y": 105
    }
  ]
]' | tee s3-evidence/round2-header-live.txt
```

Dezelfde calls staan volledig in [round2-header-calls.json](s3-evidence/round2-header-calls.json). De probe gebruikt één serverproces en wisselt Size/Kind af, acht keer elk. Bewaar voor een nieuwe voor/na-vergelijking de uitvoer per build afzonderlijk; gebruik identieke coördinaten, pid, binaryconfiguratie en vensterlayout.

## Acceptatie

- Per kolomkop **8/8**: `ok:true`, `role:AXButton`, titel `Size` respectievelijk `Kind`.
- Geen `AXCell`/`AXRow` uit een overlappende inhoudsrij.
- Doel: iedere header-call **≤150 ms**; rapporteer ook p50 en min/max van de acht calls.
- `container` na een afgebroken walk is een eerlijke fallback, maar voldoet niet aan de 8/8-buttonacceptatie.
- `permission_missing` of een veranderd/onbereikbaar doel levert geen bruikbare snelheids- of precisieclaim op.

## Gerichte regressiesuites

```sh
script -q /dev/null swift test --no-parallel --filter 'GeometricHitTestTests|ElementAtPointTests|GroundingPrecisionTests|GroundingOCRPassTests|Phase9ToolsTests'
```

In de huidige beperkte uitvoeromgeving gebruikt Swift aanvullend `CLANG_MODULE_CACHE_PATH=/private/tmp/s3-clang-cache` en `--disable-sandbox` om de buildcache te kunnen schrijven. De volledige desktopsuite wordt niet gestart.
