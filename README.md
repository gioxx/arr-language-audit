# arr-language-audit

🇮🇹 **Italiano** (questa sezione) · 🇬🇧 [**English version** ↓](#english)

Un piccolo toolkit per trovare, nelle librerie **Radarr** / **Sonarr**, i file
multimediali che **non** hanno una traccia audio in italiano, e poi *verificare*
quelli sospetti ascoltando davvero l'audio con un modello vocale locale.

Gira su Linux e macOS (bash + Python). Nessun file multimediale viene mai
modificato: gli script producono solo report CSV. Correggere un tag, fare il
remux o riscaricare resta una decisione manuale.

> I controlli sono fissati sull'italiano perché è ciò che serve all'autore. La
> logica è abbastanza semplice da adattare a un'altra lingua (vedi
> [Adattare a un'altra lingua](#adattare-a-unaltra-lingua)).

## Perché esiste

Radarr e Sonarr espongono un campo `mediaInfo.audioLanguages` per ogni file. È
comodo ma **non affidabile**:

- può **mancare** (import vecchi, file mai ri-scansionati);
- può essere **sbagliato** (release etichettata male, il tag del contenitore
  dice `ita` ma l'audio reale è inglese, o viceversa);
- riflette il **tag del contenitore**, non il parlato.

Da qui un approccio in due fasi:

1. **Fase 1 (veloce, solo API)** si fida del tag come primo filtro ed elenca
   ogni file il cui tag non è esplicitamente italiano.
2. **Fase 2 (lenta, analisi audio locale)** prende quell'elenco, estrae un breve
   campione audio da ogni file ed esegue
   [faster-whisper](https://github.com/SYSTRAN/faster-whisper) in locale (CPU,
   nessun servizio esterno) per rilevare la lingua **realmente parlata**. Ogni
   file riceve un verdetto:
   - `MISTAGGED_IS_ITALIAN` — falso positivo; l'audio *è* italiano, era solo il
     tag ad essere sbagliato. Correggi il tag, niente da scaricare.
   - `CONFIRMED_NOT_ITALIAN` — problema reale; riscarica o fai il remux di una
     traccia italiana.

## Struttura del repository

```
arr-language-audit/
├── arr-language-audit.sh        orchestratore interattivo (punto d'ingresso consigliato)
├── README.md
├── LICENSE                       MIT
├── .gitignore
├── .env.example                  template di configurazione fase 1 (copia in .env)
├── scan/
│   └── find-missing-italian-audio.sh     fase 1 (bash + curl + jq)
├── verify/
│   ├── verify-audio-language.sh          fase 2: launcher / controlli pre-volo
│   ├── verify_audio_language.py          fase 2: worker (ffmpeg + faster-whisper)
│   └── report.py                         fase 2: da CSV a report HTML (+ viewer opzionale)
└── reports/                     output (CSV, cache, HTML) — creata al primo run, git-ignored
```

## Prerequisiti

**Fase 1:** `bash`, `curl`, `jq` e accesso di rete alle API di Radarr/Sonarr.

**Fase 2:** tutto quanto sopra, più:

- `ffmpeg` / `ffprobe`
- `python3` con `pip`
- il pacchetto Python `faster-whisper` (lo installi tu — lo script non installa
  mai nulla da solo; stampa i comandi esatti e si ferma)
- **accesso diretto al filesystem dove risiedono i file media.** La fase 2 legge
  i percorsi dei file dal CSV della fase 1 e apre quei file per campionarne
  l'audio. Le sole API di Radarr/Sonarr **non bastano** per la fase 2: la
  macchina che la esegue deve vedere gli stessi percorsi (stesso host, o la
  libreria montata nella stessa posizione, ad es. via NFS/SMB).
- spazio libero sufficiente nella directory temporanea per un breve campione WAV
  alla volta (soglia di default: 500 MB).

`faster-whisper` viene cercato prima nel `python3` di sistema, poi in un
virtual environment locale in `verify/venv`. Su Debian/Ubuntu, dove il Python di
sistema è "externally managed" (PEP 668), il launcher verifica anche che
`python3 -m venv` funzioni davvero e, se manca `ensurepip`, ti indica il
pacchetto apt `pythonX.Y-venv` corretto da installare.

## Avvio rapido

Il modo più semplice è l'orchestratore interattivo: gestisce entrambe le fasi
e il report da un unico menu, passando sempre percorsi espliciti, così non
importa da quale cartella lo lanci.

```bash
cd arr-language-audit
./arr-language-audit.sh
```

All'avvio fa un pre-check: carica `.env`, verifica le dipendenze e interroga
Radarr/Sonarr (`/api/v3/system/status`), così l'intestazione mostra cosa è
connesso, quale versione e — in *Connection details* — le root folder con
accessibilità e spazio libero, e propone il passo successivo sensato
(marcato *(recommended)* e preselezionato). Menu: *Scan (fase 1)* → *Verify
(fase 2)* → *Build / Serve HTML report* → *Run full pipeline* → *Set up phase 2*
(crea `verify/venv` e installa `faster-whisper`, con conferma), con
*Connection details*, *Reconfigure (.env)*, *Reset reports* (cancella
CSV/HTML/cache in `reports/` per ricominciare, con conferma) e *About* in
fondo. Usa `whiptail` se disponibile (dialoghi ncurses), altrimenti
un menu numerato. Tutti gli output finiscono in `reports/`.

Le sezioni seguenti descrivono i singoli script, se preferisci lanciarli a
mano. Non serve più stare in una cartella precisa: i default puntano a
`<repo>/reports/`, quindi fase 1 e fase 2 si trovano sempre.

### Fase 1 — elenca i file senza tag italiano

```bash
cd arr-language-audit
./scan/find-missing-italian-audio.sh
```

Al primo avvio interattivo senza configurazione, un wizard prova a rilevare
automaticamente un Radarr locale (porta 7878) e un Sonarr locale (porta 8989)
tramite l'endpoint non autenticato `/ping`, chiede solo la API key quando ne
trova uno, e offre di salvare tutto in un file `.env` nella radice del repo. Se
non rileva nulla, chiede l'URL completo.

Preferisci configurarlo a mano:

```bash
cp .env.example .env
# modifica .env: imposta RADARR_URL / RADARR_API_KEY / SONARR_URL / SONARR_API_KEY
./scan/find-missing-italian-audio.sh
```

Output: `reports/missing-italian-audio.csv` con colonne
`App,Title,Year,Episode,AudioLanguages,Path`. Se non ci sono risultati, il file
non viene lasciato sul disco.

Tag non aggiornati? Forza prima Radarr/Sonarr a rileggere ogni file dal disco:

```bash
FORCE_RESCAN=true ./scan/find-missing-italian-audio.sh
```

**Cache Sonarr.** Sonarr viene interrogato una volta per serie (episodi con il
file incluso nella risposta). Accanto al CSV viene scritto un file
`missing-italian-audio.cache.json` che registra, per ogni serie, una firma
(numero di file + dimensione su disco secondo Sonarr). Al run successivo una
serie con firma invariata non viene ri-scaricata: le sue righe vengono
riemesse dalla cache. Per forzare una scansione completa:

```bash
./scan/find-missing-italian-audio.sh --refresh      # oppure REFRESH=true
```

Radarr non ha cache: `/api/v3/movie` restituisce già tutto in una richiesta.

### Fase 2 — verifica cosa viene davvero parlato

```bash
./verify/verify-audio-language.sh
```

Default: legge `reports/missing-italian-audio.csv`, scrive
`reports/verified-language-results.csv` con colonne
`App,Title,Year,Episode,DeclaredAudioLanguages,DetectedLanguage,Confidence,Verdict,Path,FileSize,FileMtime`.
`FileSize`/`FileMtime` sono la firma del file al momento della verifica: servono
al resume per accorgersi che un file è stato sostituito (vedi sotto).

Se manca una dipendenza lo script stampa il comando di installazione esatto ed
esce senza cambiare nulla. Un tipico primo setup su Debian/Ubuntu:

```bash
sudo apt install -y ffmpeg python3-venv
python3 -m venv verify/venv
"verify/venv/bin/pip" install --upgrade pip
"verify/venv/bin/pip" install faster-whisper
./verify/verify-audio-language.sh          # rileva e usa verify/venv automaticamente
```

L'esecuzione è riprendibile: interrompila quando vuoi e rilanciala — i file già
verificati nel CSV di output vengono riusati. Un file viene **ri-verificato
automaticamente** se la sua dimensione o il suo `mtime` sono cambiati dall'ultima
volta (l'hai sostituito, ricodificato o riscaricato), anche se il percorso è
identico. Le righe scritte da versioni precedenti non hanno `FileSize`/`FileMtime`
e vengono riusate così come sono finché non le riverifichi.

Se una riga ha un file che la fase 1 non elenca più: viene **rimossa** se quel
file è anche cambiato su disco (l'hai sistemato — il verdetto vecchio sarebbe
falso), altrimenti viene **mantenuta** (scan con scope ridotto per `SKIP_*` o
un'app giù, oppure file sparito). Per ripartire davvero da zero usa "Reset
reports" nell'orchestratore, oppure `NO_RESUME=true` per rigenerare solo questo
CSV. Per riprovare solo le righe fallite, usa `RETRY_ERRORS=true`.

Percorsi personalizzati:

```bash
./verify/verify-audio-language.sh /percorso/input.csv /percorso/output.csv
```

### Report della fase 2 (HTML)

Il CSV è l'output canonico. `verify/report.py` lo trasforma in un singolo file
HTML autonomo (CSS + JS inline, nessuna risorsa esterna, funziona offline) più
facile da navigare: chip di filtro per verdetto, ricerca testuale su
titolo/percorso, colonne ordinabili, barra di riepilogo e pulsanti "copy path" /
"copy visible paths" per costruire una lista di file da riscaricare. Solo
libreria standard, nessuna dipendenza aggiuntiva.

```bash
./verify/report.py                       # legge reports/verified-language-results.csv
                                         # scrive reports/verified-language-results.html
./verify/report.py results.csv -o out.html
```

Per consultarlo da un'altra macchina, aggiungi `--serve`: avvia un piccolo
webserver, stampa l'URL e resta in attesa — premi **Invio** per fermarlo. Dopo
non resta nulla in esecuzione (il file `.html` resta, come il CSV).

```bash
./verify/report.py --serve               # bind su 0.0.0.0, porta libera
./verify/report.py --serve --port 8080
```

L'URL servito contiene un token di accesso casuale (`?k=...`); le richieste
senza token valido ricevono `403`. Poiché il report contiene percorsi completi
del filesystem, tratta l'URL come sensibile: su una rete non fidata preferisci un
tunnel SSH con `--host 127.0.0.1`, oppure disattiva del tutto il controllo del
token con `--no-token` se sai che la porta è al sicuro.

| Opzione        | Default          | Significato |
|----------------|------------------|-------------|
| `-o, --output` | percorso CSV `.html` | Percorso dell'HTML di output |
| `--serve`      | off              | Serve l'HTML e attende l'Invio |
| `--host`       | `0.0.0.0`        | Indirizzo di bind quando serve |
| `--port`       | `0` (porta libera) | Porta di bind quando serve |
| `--no-token`   | off              | Serve senza il controllo del token `?k=` |

## Configurazione

### Variabili d'ambiente — fase 1

Lette dall'ambiente, oppure da un file `.env` cercato (in ordine) in `scan/`,
nella radice del repo, poi nella directory corrente — vince la prima occorrenza.

| Variabile        | Default                  | Significato |
|------------------|--------------------------|-------------|
| `RADARR_URL`     | `http://localhost:7878`  | URL base di Radarr |
| `RADARR_API_KEY` | —                        | API key di Radarr |
| `SONARR_URL`     | `http://localhost:8989`  | URL base di Sonarr |
| `SONARR_API_KEY` | —                        | API key di Sonarr |
| `SKIP_RADARR`    | `false`                  | `true` per saltare del tutto Radarr |
| `SKIP_SONARR`    | `false`                  | `true` per saltare del tutto Sonarr |
| `FORCE_RESCAN`   | `false`                  | `true` per eseguire `RescanMovie` / `RescanSeries` prima di leggere `mediaInfo` |
| `RESCAN_TIMEOUT` | `300`                    | Secondi di attesa per il completamento del comando di rescan |
| `REFRESH`        | `false`                  | `true` per ignorare la cache Sonarr e ri-scaricare ogni serie (come `--refresh`) |

Il primo argomento posizionale sovrascrive il percorso del CSV di output:
`./scan/find-missing-italian-audio.sh /tmp/report.csv`. Il flag `--refresh`
ignora la cache Sonarr per quel run.

### Variabili d'ambiente — fase 2

| Variabile           | Default   | Significato |
|---------------------|-----------|-------------|
| `WHISPER_MODEL`     | `small`   | `tiny` \| `base` \| `small` \| `medium` — più grande = più accurato e più lento |
| `SAMPLE_SECONDS`    | `60`      | Lunghezza del campione audio analizzato per file |
| `SAMPLE_OFFSET_PCT` | `25`      | Da dove iniziare il campionamento, in percentuale sulla durata totale (salta le intro) |
| `MIN_FREE_SPACE_MB` | `500`     | Spazio libero minimo richiesto nella directory temporanea |
| `TEMP_DIR`          | `mktemp`  | Directory per i campioni WAV temporanei |
| `LIMIT`             | —         | Processa solo i primi N nuovi file (utile per un test) |
| `RETRY_ERRORS`      | `false`   | `true` per riprocessare anche le righe il cui verdetto precedente era un errore |
| `NO_RESUME`         | `false`   | `true` per ignorare un CSV di output esistente e ripartire da zero |

Entrambi gli script accettano anche `-h` / `--help`.

## Verdetti di output (fase 2)

| Verdetto                | Significato | Azione suggerita |
|-------------------------|-------------|------------------|
| `MISTAGGED_IS_ITALIAN`  | L'audio è italiano; il tag era sbagliato | Correggi il tag / mediaInfo, rescan |
| `CONFIRMED_NOT_ITALIAN` | L'audio davvero non è italiano | Riscarica o fai il remux di una traccia italiana |
| `FILE_NOT_FOUND`        | Il percorso dal CSV della fase 1 non è visibile su questa macchina | Monta la libreria, o esegui la fase 2 dove risiedono i file |
| `EXTRACTION_FAILED`     | `ffmpeg` non è riuscito a produrre un campione | Ispeziona il file manualmente |
| `DETECTION_FAILED`      | `faster-whisper` ha sollevato un errore sul campione | Riprova con `RETRY_ERRORS=true`, o con un modello più grande |

`DetectedLanguage` è un codice ISO (`it`, `en`, `de`, …); `Confidence` è la
probabilità di rilevamento lingua del modello (`0.00`–`1.00`).

## Note e limiti

- Il rilevamento lingua gira su un singolo campione di ~60 s. Film che si aprono
  con un lungo tratto senza dialoghi, o che mescolano lingue, possono comunque
  ingannarlo — regola `SAMPLE_SECONDS` / `SAMPLE_OFFSET_PCT`, o alza
  `WHISPER_MODEL`.
- Viene analizzata solo la **prima traccia audio / quella di default** nel
  campione. Un file con traccia di default inglese più una traccia italiana
  secondaria verrà segnalato come `CONFIRMED_NOT_ITALIAN` — cosa che, per
  "l'audio di default non è italiano", è probabilmente corretta, ma è bene
  saperlo.
- Tutto è locale: nessun audio e nessun metadato lascia la tua macchina.

## Adattare a un'altra lingua

- **Fase 1:** modifica `ITALIAN_REGEX` in `scan/find-missing-italian-audio.sh`.
- **Fase 2:** modifica `is_italian()` in `verify/verify_audio_language.py` e le
  stringhe dei verdetti.

## Licenza

[MIT](LICENSE) - 2026 Giovanni Solone

---

<a id="english"></a>

# arr-language-audit (English)

🇬🇧 **English** (this section) · 🇮🇹 [**Versione italiana** ↑](#arr-language-audit)

A small toolkit to find media files in your **Radarr** / **Sonarr** libraries
that do **not** have an Italian audio track, and then to *verify* the
suspicious ones by actually listening to the audio with a local speech model.

Runs on Linux and macOS (bash + Python). No media file is ever modified: the
scripts only produce CSV reports. Fixing a tag, remuxing, or re-downloading
stays a manual decision.

> The checks are hard-coded to Italian because that is what the author needs.
> The logic is simple enough to adapt to another language (see
> [Adapting to another language](#adapting-to-another-language)).

## Why this exists

Radarr and Sonarr expose a `mediaInfo.audioLanguages` field per file. It is
convenient but **not reliable**:

- it can be **missing** (older imports, files never rescanned);
- it can be **wrong** (mislabelled release, container tag says `ita` but the
  actual audio is English, or vice versa);
- it reflects the **container tag**, not the speech.

So a two-phase approach:

1. **Phase 1 (fast, API only)** trusts the tag as a first filter and lists
   every file whose tag is not explicitly Italian.
2. **Phase 2 (slow, local audio analysis)** takes that list, extracts a short
   audio sample from each file, and runs
   [faster-whisper](https://github.com/SYSTRAN/faster-whisper) locally (CPU,
   no external service) to detect the language **actually spoken**. Each file
   ends up with a verdict:
   - `MISTAGGED_IS_ITALIAN` — false positive; the audio *is* Italian, only the
     tag was wrong. Fix the tag, nothing to download.
   - `CONFIRMED_NOT_ITALIAN` — real problem; redownload or remux an Italian
     track.

## Repository layout

```
arr-language-audit/
├── arr-language-audit.sh        interactive orchestrator (recommended entry point)
├── README.md
├── LICENSE                       MIT
├── .gitignore
├── .env.example                  phase 1 config template (copy to .env)
├── scan/
│   └── find-missing-italian-audio.sh     phase 1 (bash + curl + jq)
├── verify/
│   ├── verify-audio-language.sh          phase 2 launcher / pre-flight checks
│   ├── verify_audio_language.py          phase 2 worker (ffmpeg + faster-whisper)
│   └── report.py                         phase 2 CSV -> HTML report (+ optional viewer)
└── reports/                     output (CSV, cache, HTML) — created on first run, git-ignored
```

## Requirements

**Phase 1:** `bash`, `curl`, `jq`, and network access to your Radarr/Sonarr
API.

**Phase 2:** everything above plus:

- `ffmpeg` / `ffprobe`
- `python3` with `pip`
- the `faster-whisper` Python package (installed by you — the script never
  installs anything on its own; it prints the exact commands and stops)
- **direct filesystem access to the actual media files.** Phase 2 reads the
  file paths from the phase 1 CSV and opens those files to sample their audio.
  The Radarr/Sonarr API alone is **not enough** for phase 2 — the machine
  running it must see the same paths (same host, or the library mounted at the
  same location, e.g. over NFS/SMB).
- enough free disk space in the temp directory for one short WAV sample at a
  time (default guard: 500 MB).

`faster-whisper` is looked for first in the system `python3`, then in a local
virtual environment at `verify/venv`. On Debian/Ubuntu, where the system
Python is externally managed (PEP 668), the launcher also checks that
`python3 -m venv` actually works and, if `ensurepip` is missing, tells you the
right `pythonX.Y-venv` apt package to install.

## Quickstart

The easiest way is the interactive orchestrator: it drives both phases and
the report from one menu, always passing explicit paths, so it does not
matter which directory you run it from.

```bash
cd arr-language-audit
./arr-language-audit.sh
```

On launch it runs a pre-flight: it loads `.env`, checks the tools each phase
needs, and queries Radarr/Sonarr (`/api/v3/system/status`) so the header shows
what is connected, which version, and — under *Connection details* — the root
folders with their accessibility and free space, and it suggests the next
sensible step (tagged *(recommended)* and pre-selected). Menu: *Scan (phase 1)*
→ *Verify (phase 2)* → *Build / Serve HTML report* → *Run full pipeline* →
*Set up phase 2* (creates `verify/venv` and installs `faster-whisper`, with
confirmation), plus *Connection details*, *Reconfigure (.env)*, *Reset reports*
(deletes the CSV/HTML/cache files in `reports/` to start over, with
confirmation) and *About*. It uses `whiptail` when
available (ncurses dialogs) and falls back to a plain numbered prompt. All
output lands in `reports/`.

The sections below document each script for running them by hand. You no
longer need to be in a specific directory: the defaults point at
`<repo>/reports/`, so phase 1 and phase 2 always meet.

### Phase 1 — list files without an Italian tag

```bash
cd arr-language-audit
./scan/find-missing-italian-audio.sh
```

On the first interactive run with no configuration, a wizard tries to
auto-detect a local Radarr (port 7878) and Sonarr (port 8989) through the
unauthenticated `/ping` endpoint, asks only for the API key when it finds
one, and offers to save everything to a `.env` file in the repo root. If
nothing is detected it asks for the full URL instead.

Prefer to configure it by hand:

```bash
cp .env.example .env
# edit .env: set RADARR_URL / RADARR_API_KEY / SONARR_URL / SONARR_API_KEY
./scan/find-missing-italian-audio.sh
```

Output: `reports/missing-italian-audio.csv` with columns
`App,Title,Year,Episode,AudioLanguages,Path`. If there are no findings the
file is not left behind.

Stale tags? Force Radarr/Sonarr to re-read every file from disk first:

```bash
FORCE_RESCAN=true ./scan/find-missing-italian-audio.sh
```

**Sonarr cache.** Sonarr is queried once per series (episodes with the file
embedded in the response). A `missing-italian-audio.cache.json` file is
written next to the CSV, recording a per-series signature (file count + size
on disk as reported by Sonarr). On the next run a series whose signature is
unchanged is not re-fetched: its rows are re-emitted from the cache. Force a
full re-scan with:

```bash
./scan/find-missing-italian-audio.sh --refresh      # or REFRESH=true
```

Radarr has no cache: `/api/v3/movie` already returns everything in one request.

### Phase 2 — verify what is actually spoken

```bash
./verify/verify-audio-language.sh
```

Defaults: reads `reports/missing-italian-audio.csv`, writes
`reports/verified-language-results.csv` with columns
`App,Title,Year,Episode,DeclaredAudioLanguages,DetectedLanguage,Confidence,Verdict,Path,FileSize,FileMtime`.
`FileSize`/`FileMtime` record the file's signature at verification time; the
resume logic uses them to notice a file was replaced (see below).

If a dependency is missing the script prints the exact install command and
exits without changing anything. A typical first-time setup on Debian/Ubuntu:

```bash
sudo apt install -y ffmpeg python3-venv
python3 -m venv verify/venv
"verify/venv/bin/pip" install --upgrade pip
"verify/venv/bin/pip" install faster-whisper
./verify/verify-audio-language.sh          # detects and uses verify/venv automatically
```

The run is resumable: stop it any time and run it again — files already
verified in the output CSV are reused. A file is **re-verified automatically**
when its size or mtime changed since the last run (you replaced, re-encoded or
re-downloaded it), even though its path is unchanged. Rows written by older
versions have no `FileSize`/`FileMtime` and are reused as-is until verified
again.

A row whose file is no longer listed by phase 1 is **dropped** if that file
also changed on disk (you fixed it -- the old verdict would be wrong), and
**kept** otherwise (a narrower scan scope from `SKIP_*` or a downed app, or a
missing file). To really start from scratch use "Reset reports" in the
orchestrator, or `NO_RESUME=true` to regenerate just this CSV. To retry only
the rows that failed, use `RETRY_ERRORS=true`.

Custom paths:

```bash
./verify/verify-audio-language.sh /path/to/input.csv /path/to/output.csv
```

### Phase 2 report (HTML)

The CSV is the canonical output. `verify/report.py` turns it into a single
self-contained HTML file (inline CSS + JS, no external resources, works
offline) that is easier to browse: filter chips per verdict, free-text
search on title/path, sortable columns, a summary bar, and "copy path" /
"copy visible paths" buttons to build a redownload list. Standard library
only, no extra dependencies.

```bash
./verify/report.py                       # reads reports/verified-language-results.csv
                                         # writes reports/verified-language-results.html
./verify/report.py results.csv -o out.html
```

To consult it from another machine, add `--serve`: it starts a small
webserver, prints the URL, and waits — press **Enter** to stop it. Nothing
stays running afterwards (the `.html` file itself is kept, like the CSV).

```bash
./verify/report.py --serve               # binds 0.0.0.0 on a free port
./verify/report.py --serve --port 8080
```

The served URL carries a random access token (`?k=...`); requests without a
valid token get `403`. Since the report contains full filesystem paths,
treat the URL as sensitive — on an untrusted network prefer an SSH tunnel
and `--host 127.0.0.1`, or drop the token check entirely with `--no-token`
if you know the port is safe.

| Option        | Default        | Meaning |
|---------------|----------------|---------|
| `-o, --output`| CSV path `.html` | Output HTML path |
| `--serve`     | off            | Serve the HTML and wait for Enter |
| `--host`      | `0.0.0.0`      | Bind address when serving |
| `--port`      | `0` (free port)| Bind port when serving |
| `--no-token`  | off            | Serve without the `?k=` access check |

## Configuration

### Phase 1 environment variables

Read from the environment, or from a `.env` file looked up (in order) in
`scan/`, the repo root, then the current directory — first match wins.

| Variable         | Default                  | Meaning |
|------------------|--------------------------|---------|
| `RADARR_URL`     | `http://localhost:7878`  | Radarr base URL |
| `RADARR_API_KEY` | —                        | Radarr API key |
| `SONARR_URL`     | `http://localhost:8989`  | Sonarr base URL |
| `SONARR_API_KEY` | —                        | Sonarr API key |
| `SKIP_RADARR`    | `false`                  | `true` to skip Radarr entirely |
| `SKIP_SONARR`    | `false`                  | `true` to skip Sonarr entirely |
| `FORCE_RESCAN`   | `false`                  | `true` to run `RescanMovie` / `RescanSeries` before reading `mediaInfo` |
| `RESCAN_TIMEOUT` | `300`                    | Seconds to wait for a rescan command to finish |
| `REFRESH`        | `false`                  | `true` to ignore the Sonarr cache and re-fetch every series (same as `--refresh`) |

The first positional argument overrides the output CSV path:
`./scan/find-missing-italian-audio.sh /tmp/report.csv`. The `--refresh` flag
ignores the Sonarr cache for that run.

### Phase 2 environment variables

| Variable            | Default   | Meaning |
|---------------------|-----------|---------|
| `WHISPER_MODEL`     | `small`   | `tiny` \| `base` \| `small` \| `medium` — bigger is more accurate and slower |
| `SAMPLE_SECONDS`    | `60`      | Length of the audio sample analyzed per file |
| `SAMPLE_OFFSET_PCT` | `25`      | Where to start sampling, as a percentage of total duration (skips intros) |
| `MIN_FREE_SPACE_MB` | `500`     | Minimum free space required in the temp directory |
| `TEMP_DIR`          | `mktemp`  | Directory for the temporary WAV samples |
| `LIMIT`             | —         | Only process the first N new files (useful for a test run) |
| `RETRY_ERRORS`      | `false`   | `true` to also reprocess rows whose previous verdict was an error |
| `NO_RESUME`         | `false`   | `true` to ignore an existing output CSV and start fresh |

Both scripts also accept `-h` / `--help`.

## Output verdicts (phase 2)

| Verdict                 | Meaning | Suggested action |
|-------------------------|---------|------------------|
| `MISTAGGED_IS_ITALIAN`  | Audio is Italian; the tag was wrong | Fix the tag / mediaInfo, rescan |
| `CONFIRMED_NOT_ITALIAN` | Audio really is not Italian | Redownload or remux an Italian track |
| `FILE_NOT_FOUND`        | Path from the phase 1 CSV is not visible on this machine | Mount the library, or run phase 2 where the files live |
| `EXTRACTION_FAILED`     | `ffmpeg` could not produce a sample | Inspect the file manually |
| `DETECTION_FAILED`      | `faster-whisper` raised on the sample | Retry with `RETRY_ERRORS=true`, or a larger model |

`DetectedLanguage` is an ISO code (`it`, `en`, `de`, …); `Confidence` is the
model's language-detection probability (`0.00`–`1.00`).

## Notes and limitations

- Language detection runs on a single ~60 s sample. Films that open with a
  long non-dialogue stretch, or that mix languages, can still fool it —
  adjust `SAMPLE_SECONDS` / `SAMPLE_OFFSET_PCT`, or bump `WHISPER_MODEL`.
- Only the **first / default** audio stream in the sample is analyzed. A file
  with an English default track plus a secondary Italian track will be
  reported as `CONFIRMED_NOT_ITALIAN` — which for "the default audio is not
  Italian" is arguably correct, but worth knowing.
- Everything is local: no audio and no metadata leave your machine.

## Adapting to another language

- **Phase 1:** change `ITALIAN_REGEX` in `scan/find-missing-italian-audio.sh`.
- **Phase 2:** change `is_italian()` in `verify/verify_audio_language.py` and
  the verdict strings.

## License

[MIT](LICENSE) - 2026 Giovanni Solone
