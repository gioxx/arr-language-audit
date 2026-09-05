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
   - `LOW_CONFIDENCE` — il modello ha nominato una lingua ma sotto la soglia
     `MIN_CONFIDENCE`: non decide nulla, va rieseguito.

## Struttura del repository

```
arr-language-audit/
├── arr-language-audit.sh         orchestratore interattivo (punto d'ingresso consigliato)
├── README.md
├── CHANGELOG.md                  modifiche visibili all'utente (Keep a Changelog)
├── LICENSE                       MIT
├── .gitignore
├── .env.example                  template di configurazione (copia in .env)
├── pyproject.toml                configurazione di ruff e pytest
├── lib/
│   └── common.sh                 helper condivisi: .env, log, curl *arr, scelta di Python
├── scan/
│   └── find-missing-italian-audio.sh     fase 1 (bash + curl + jq)
├── verify/
│   ├── verify-audio-language.sh          fase 2: launcher / controlli pre-volo
│   ├── verify_audio_language.py          fase 2: worker (ffmpeg + faster-whisper)
│   ├── audit_common.py                   costanti condivise (verdetti, colonne, percorsi)
│   ├── report.py                         fase 2: da CSV a report HTML (+ viewer opzionale)
│   └── requirements.txt                  dipendenza della fase 2 (faster-whisper, pinnata)
├── scripts/
│   └── test.sh                   un unico entry point per i controlli, usato anche dalla CI
├── tests/
│   ├── bats/                     suite bash (bats-core), fixture e shim di PATH
│   ├── fakes/                    Radarr/Sonarr finto e pacchetto faster_whisper stub
│   └── python/                   suite pytest
├── docs/
│   ├── adr/                      decisioni architetturali (formato MADR)
│   └── audit/                    note dell'audit e strategia di test
├── .github/workflows/ci.yml      lint + bats + pytest su Linux e macOS
└── reports/                      output (CSV, cache, HTML) — creata al primo run, git-ignored
```

## Prerequisiti

**Fase 1:** `bash` ≥ 3.2, `curl`, `jq` ≥ 1.6 e accesso di rete alle API di
Radarr/Sonarr.

I minimi sono scelti perché il toolkit deve girare su un macOS appena
installato: `bash` ≥ 3.2 è la `/bin/bash` che Apple distribuisce e Python ≥ 3.9
è l'interprete di sistema. Vedi
[docs/adr/0001-compatibility-floors.md](docs/adr/0001-compatibility-floors.md).

**Fase 2:** tutto quanto sopra, più:

- `ffmpeg` / `ffprobe`
- `python3` ≥ 3.9 con `pip`
- il pacchetto Python `faster-whisper`, installato da te a partire da
  `verify/requirements.txt` (lo script non installa mai nulla da solo; stampa i
  comandi esatti e si ferma)
- **accesso diretto al filesystem dove risiedono i file media.** La fase 2 legge
  i percorsi dei file dal CSV della fase 1 e apre quei file per campionarne
  l'audio. Le sole API di Radarr/Sonarr **non bastano** per la fase 2: la
  macchina che la esegue deve vedere gli stessi percorsi (stesso host, o la
  libreria montata nella stessa posizione, ad es. via NFS/SMB).
- spazio libero sufficiente nella directory temporanea per un breve campione WAV
  alla volta (soglia di default: 500 MB, vedi `MIN_FREE_SPACE_MB`).

L'interprete della fase 2 viene scelto in questo ordine: `PYTHON_BIN`, se
riesce a importare `faster_whisper`; poi il virtual environment locale
`verify/venv`; poi il `python3` di sistema. Un `PYTHON_BIN` che non importa il
pacchetto viene segnalato e ignorato, non usato in silenzio. L'interprete
scelto deve essere Python ≥ 3.9: la verifica avviene nei controlli pre-volo,
non a metà di una scansione da ore.

Su Debian/Ubuntu, dove il Python di sistema è "externally managed" (PEP 668), il
launcher verifica anche che `python3 -m venv` funzioni davvero e, se manca
`ensurepip`, ti indica il pacchetto apt `pythonX.Y-venv` corretto da installare.

**Primo avvio della fase 2:** `faster-whisper` scarica il modello scelto da
Hugging Face e lo mette in cache. È l'unico momento in cui serve la rete: dai
run successivi in poi la fase 2 lavora completamente offline. Cambiare
`WHISPER_MODEL` fa scaricare quel modello una volta.

## Avvio rapido

Il modo più semplice è l'orchestratore interattivo: gestisce entrambe le fasi
e il report da un unico menu, passando sempre percorsi espliciti, così non
importa da quale cartella lo lanci.

```bash
cd arr-language-audit
./arr-language-audit.sh
```

All'avvio fa un pre-check: carica `.env`, verifica le dipendenze, chiede al
launcher della fase 2 (`verify-audio-language.sh --check`) se il suo ambiente è
pronto e interroga Radarr/Sonarr (`/api/v3/system/status`), così l'intestazione
mostra cosa è connesso, quale versione e — in *Connection details* — le root
folder con accessibilità e spazio libero, e propone il passo successivo sensato
(marcato *(recommended)* e preselezionato). Menu: *Scan (fase 1)* → *Verify
(fase 2)* → *Build / Serve HTML report* → *Run full pipeline* → *Set up phase 2*
(crea `verify/venv` e installa `verify/requirements.txt`, con conferma), con
*Connection details*, *Reconfigure (.env)*, *Reset reports* (cancella
CSV/HTML/cache in `reports/` per ricominciare, con conferma) e *About* in
fondo. Usa `whiptail` se disponibile (dialoghi ncurses), altrimenti
un menu numerato — `ARR_PLAIN_MENU`, impostata a qualsiasi valore, forza il
menu numerato anche con `whiptail` installato. Tutti gli output finiscono in
`reports/`.

Se la fase 1 esce con 2 (un'app abilitata non raggiunta) o la fase 2 esce con 3
(nessun file verificato con successo), l'orchestratore lo dice a schermo e
lascia intatto il report precedente invece di far passare l'errore in silenzio.
Le API key non vengono mai esportate: `ffmpeg`, whisper e il report girano con
`RADARR_API_KEY` / `SONARR_API_KEY` rimosse dall'ambiente.

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
trova uno, e offre di salvare tutto in un file `.env` nella radice del repo
(scritto con permessi 600). Se non rileva nulla, chiede l'URL completo. Gli
input sono validati: l'URL deve essere `http://` o `https://` senza spazi, la
API key solo lettere e cifre, così un incolla che ha raccolto virgolette o
spazi viene rifiutato al prompt e non a ogni run.

Preferisci configurarlo a mano:

```bash
cp .env.example .env
# modifica .env: imposta RADARR_URL / RADARR_API_KEY / SONARR_URL / SONARR_API_KEY
./scan/find-missing-italian-audio.sh
```

Output: `reports/missing-italian-audio.csv` con colonne
`App,Title,Year,Episode,AudioLanguages,Path`. Se non ci sono risultati il file
viene comunque scritto, con la sola riga di intestazione.

Il report viene costruito in `<OUTPUT_CSV>.tmp.<pid>` e spostato al suo posto
alla fine, così nessun lettore vede un file parziale. Essendo una rinomina, il
report prende i permessi di un file nuovo, non quelli di quello che sostituisce.

Codici di uscita:

| Codice | Significato |
|--------|-------------|
| `0`    | scansione completata (con o senza risultati); il report è stato sostituito |
| `1`    | dipendenza mancante (`jq` / `curl`) oppure argomenti errati |
| `2`    | un'app abilitata non è stata elencata dopo i retry: il file temporaneo viene scartato, quindi un report precedente sopravvive intatto |

Tag non aggiornati? Forza prima Radarr/Sonarr a rileggere ogni file dal disco:

```bash
FORCE_RESCAN=true ./scan/find-missing-italian-audio.sh
```

`FORCE_RESCAN=true` implica `REFRESH=true`: un rescan puo' cambiare i tag
senza cambiare la firma della serie, e la cache nasconderebbe proprio cio'
per cui e' stato chiesto. L'attesa del rescan dura al massimo
`RESCAN_TIMEOUT` secondi (default 900), con un polling ogni
`RESCAN_POLL_INTERVAL` secondi (default 5); un rescan che riporta *failed*,
*aborted*, *cancelled* o *orphaned* non viene atteso fino alla scadenza: la
scansione avvisa e prosegue.

**Cache Sonarr.** Sonarr viene interrogato una volta per serie (episodi con il
file incluso nella risposta). Accanto al CSV viene scritto un file
`missing-italian-audio.cache.json` che registra, per ogni serie, una firma
(numero di file + dimensione su disco secondo Sonarr) e le righe che quella
serie ha prodotto. Al run successivo una serie con firma invariata non viene
ri-scaricata: le sue righe vengono riemesse dalla cache.

La cache è alla versione 2: porta un blocco `__meta` con la versione dello
schema e la regex italiana con cui è stata costruita. Una cache scritta da
un'altra versione, o con un'altra regex, viene scartata e ricostruita — così
cambiare `ITALIAN_REGEX` non lascia in giro verdetti calcolati con la regex
precedente. Per forzare una scansione completa:

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

Per controllare solo l'ambiente, senza verificare niente:

```bash
./verify/verify-audio-language.sh --check
```

`--check` è accettata in qualsiasi posizione, quindi
`./verify/verify-audio-language.sh in.csv --check` controlla l'ambiente per
quell'input senza eseguire nulla. È la stessa domanda che si fa
l'orchestratore: se il launcher dice che la fase 2 è pronta, lo è.

Se manca una dipendenza lo script stampa il comando di installazione esatto ed
esce senza cambiare nulla. Un tipico primo setup su Debian/Ubuntu:

```bash
sudo apt install -y ffmpeg python3-venv
python3 -m venv verify/venv
"verify/venv/bin/pip" install --upgrade pip
"verify/venv/bin/pip" install -r verify/requirements.txt
./verify/verify-audio-language.sh          # rileva e usa verify/venv automaticamente
```

L'esecuzione è riprendibile: interrompila quando vuoi e rilanciala — i file già
verificati nel CSV di output vengono riusati. Le righe sono accoppiate su
`(percorso, episodio)`, non sul solo percorso: un file che contiene un doppio
episodio sono due righe Sonarr con lo stesso percorso, e ognuna conserva il suo
verdetto.

Un file viene **ri-verificato automaticamente** se la sua dimensione o il suo
`mtime` sono cambiati dall'ultima volta (l'hai sostituito, ricodificato o
riscaricato), anche se il percorso è identico. Le righe scritte da versioni
precedenti non hanno `FileSize`/`FileMtime` e vengono riusate così come sono
finché non le riverifichi. Una riga di errore senza firma (tipicamente un
`FILE_NOT_FOUND` di un run in cui la condivisione non era montata) viene
riprovata appena il file è di nuovo visibile, e non viene mai marcata con una
firma su cui non è stata verificata.

Se una riga ha un file che la fase 1 non elenca più: viene **rimossa** se quel
file è anche cambiato su disco (l'hai sistemato — il verdetto vecchio sarebbe
falso), altrimenti viene **mantenuta** (scan con scope ridotto per `SKIP_*` o
un'app giù, oppure file sparito). Un episodio che la fase 1 rietichetta
conserva il suo verdetto: la riga con la vecchia etichetta viene sostituita e
rimossa, e il verdetto si sposta su quella nuova finché la firma del file non
cambia — rinominare un episodio non costa un nuovo ascolto e non lascia lo
stesso file due volte nel report.

`LIMIT` (variabile d'ambiente del launcher; il worker accetta `--limit`)
limita quanti file vengono (ri)verificati in un run: le
righe che taglia conservano il verdetto che avevano già, quindi un run limitato
non svuota mai il report. Per ripartire davvero da zero usa "Reset reports"
nell'orchestratore, oppure `NO_RESUME=true` per rigenerare solo questo CSV. Per
riprovare le righe riprovabili — `FILE_NOT_FOUND`, `EXTRACTION_FAILED`,
`DETECTION_FAILED` e anche `LOW_CONFIDENCE` — usa `RETRY_ERRORS=true`.

Percorsi personalizzati:

```bash
./verify/verify-audio-language.sh /percorso/input.csv /percorso/output.csv
```

Codici di uscita del worker:

| Codice | Significato |
|--------|-------------|
| `0`    | terminato (anche quando non c'era niente di nuovo da verificare) |
| `1`    | problema di configurazione, input, percorso di output, spazio disco, oppure il modello non si è caricato (il CSV precedente resta intatto) |
| `2`    | errore d'uso: flag sconosciuta o valore non valido (argparse) |
| `3`    | ogni file che questo run ha provato a verificare è andato in errore |
| `130`  | interrotto (Ctrl-C); il CSV scritto fino a quel punto resta valido |

Il launcher restituisce `1` per i suoi errori d'uso e per i controlli pre-volo
falliti, e per il resto lascia passare invariati i codici del worker. Il `2`
arriva sempre dal worker: chiamandolo a mano con una flag sbagliata, oppure
passando al launcher un `LIMIT` non numerico, che viene inoltrato come
`--limit` e respinto da argparse.

### Report della fase 2 (HTML)

Il CSV è l'output canonico. `verify/report.py` lo trasforma in un singolo file
HTML autonomo (CSS + JS inline, nessuna risorsa esterna, funziona offline) più
facile da navigare: chip di filtro per verdetto, ricerca testuale su
titolo/percorso, colonne ordinabili, barra di riepilogo e pulsanti "copy path" /
"copy visible paths" per costruire una lista di file da riscaricare. Solo
libreria standard, nessuna dipendenza aggiuntiva.

Per restare leggero su librerie grandi la tabella si ferma a 2000 righe e
mostra un pulsante *Show all N rows* per renderle tutte.

```bash
./verify/report.py                       # legge reports/verified-language-results.csv
                                         # scrive reports/verified-language-results.html
./verify/report.py results.csv -o out.html
```

Per consultarlo da un'altra macchina, aggiungi `--serve`: avvia un piccolo
webserver, stampa l'URL e resta in attesa — premi **Invio** per fermarlo. Dopo
non resta nulla in esecuzione (il file `.html` resta, come il CSV).

```bash
./verify/report.py --serve                      # bind su 127.0.0.1, porta libera
./verify/report.py --serve --host 0.0.0.0       # esposto sulla LAN
./verify/report.py --serve --port 8080
```

Il bind di default è **`127.0.0.1`**: senza dirlo, il report non è raggiungibile
da altre macchine. Serve `--host 0.0.0.0` per esporlo sulla LAN, e
l'orchestratore lo chiede esplicitamente prima di farlo.

L'URL servito contiene un token di accesso casuale (`?k=...`); le richieste
senza token valido ricevono `403`. Le risposte viaggiano con
`Cache-Control: no-store`, `Referrer-Policy: no-referrer` e
`X-Content-Type-Options: nosniff`. Poiché il report contiene percorsi completi
del filesystem, tratta comunque l'URL come sensibile: su una rete non fidata
preferisci un tunnel SSH con il bind di default, oppure disattiva del tutto il
controllo del token con `--no-token` se sai che la porta è al sicuro.

| Opzione        | Default          | Significato |
|----------------|------------------|-------------|
| `-o, --output` | percorso CSV `.html` | Percorso dell'HTML di output |
| `--serve`      | off              | Serve l'HTML e attende l'Invio |
| `--host`       | `127.0.0.1`      | Indirizzo di bind quando serve (`0.0.0.0` per esporre sulla LAN) |
| `--port`       | `0` (porta libera) | Porta di bind quando serve |
| `--no-token`   | off              | Serve senza il controllo del token `?k=` |

Uscita `0` quando l'HTML è stato scritto (e, con `--serve`, il server è stato
fermato correttamente), `1` se il CSV di input non c'è o non è leggibile, o se
la porta richiesta non è utilizzabile.

## Configurazione

### Il file `.env`

Il file viene cercato, **in quest'ordine**, in `<repo>/.env` e poi in
`<repo>/scan/.env`: vince la prima occorrenza. La **directory corrente non
viene letta**: lanciare l'audit da una cartella su cui scrive qualcun altro non
deve cambiare cosa fa. `ALA_DOTENV_FILE`, se impostata e non vuota, sostituisce
del tutto la ricerca con il file che indica, e se quel file non esiste riporta
"nessun .env" invece di ricadere sulla ricerca.

Il file viene **analizzato, non eseguito**: mai `source`, mai `eval`. Un `.env`
è spesso leggibile da tutti e a volte condiviso, e caricarlo con `source`
regalerebbe a chi può scriverlo l'esecuzione di codice arbitrario. Di
conseguenza:

- il formato è `KEY=value`, una per riga; righe vuote e commenti `#` vengono
  saltati, e l'indentazione è ammessa;
- una riga malformata viene segnalata (con il numero di riga, mai il contenuto:
  potrebbe contenere buona parte di una API key) e ignorata;
- viene rimossa una sola coppia di virgolette che racchiude il valore, e nulla
  altro viene interpretato: **i valori non subiscono espansione di shell** —
  `$HOME`, `$(...)` e le backquote restano testo letterale;
- solo le chiavi in allow-list vengono impostate; qualsiasi altra chiave viene
  segnalata e scartata, così un `.env` non è una via per raggiungere `PATH`,
  `LD_PRELOAD` o `IFS`;
- niente viene esportato dal loader: chi vuole che un valore arrivi a un
  processo figlio lo esporta esplicitamente.

**Precedenza:** flag da riga di comando > variabile d'ambiente già impostata e
non vuota > `.env` > default. Quindi `LIMIT=5 ./verify/verify-audio-language.sh`
batte quello che dice `.env`, e `--refresh` batte entrambi.

### Variabili d'ambiente — fase 1

| Variabile        | Default                  | Significato |
|------------------|--------------------------|-------------|
| `RADARR_URL`     | `http://localhost:7878`  | URL base di Radarr |
| `RADARR_API_KEY` | —                        | API key di Radarr |
| `SONARR_URL`     | `http://localhost:8989`  | URL base di Sonarr |
| `SONARR_API_KEY` | —                        | API key di Sonarr |
| `SKIP_RADARR`    | `false`                  | `true` per saltare del tutto Radarr |
| `SKIP_SONARR`    | `false`                  | `true` per saltare del tutto Sonarr |
| `FORCE_RESCAN`   | `false`                  | `true` per eseguire `RescanMovie` / `RescanSeries` prima di leggere `mediaInfo`; implica `REFRESH=true` |
| `RESCAN_TIMEOUT` | `900`                    | Secondi di attesa per il completamento del comando di rescan |
| `RESCAN_POLL_INTERVAL` | `5`                | Secondi tra due letture dello stato del rescan |
| `REFRESH`        | `false`                  | `true` per ignorare la cache Sonarr e ri-scaricare ogni serie (come `--refresh`) |

Il primo argomento posizionale sovrascrive il percorso del CSV di output:
`./scan/find-missing-italian-audio.sh /tmp/report.csv`. Il flag `--refresh`
ignora la cache Sonarr per quel run.

### Variabili d'ambiente — fase 2

| Variabile           | Default   | Significato |
|---------------------|-----------|-------------|
| `PYTHON_BIN`        | —         | Interprete con cui eseguire la fase 2; se non importa `faster_whisper` viene segnalato e ignorato |
| `WHISPER_MODEL`     | `small`   | `tiny` \| `base` \| `small` \| `medium` — più grande = più accurato e più lento |
| `WHISPER_THREADS`   | tutti i core | Thread CPU per il modello |
| `SAMPLE_SECONDS`    | `60`      | Lunghezza del campione audio analizzato per file |
| `SAMPLE_OFFSET_PCT` | `25`      | Da dove iniziare il campionamento, in percentuale sulla durata totale (salta le intro) |
| `MIN_CONFIDENCE`    | `0.6`     | Da `0` a `1`: sotto questa soglia il rilevamento diventa `LOW_CONFIDENCE` |
| `MIN_FREE_SPACE_MB` | `500`     | Spazio libero minimo richiesto nella directory temporanea |
| `TEMP_DIR`          | temp di sistema | Directory **genitore** dei campioni: il run crea al suo interno una `lang-check-*` privata e rimuove solo quella. La directory che indichi non viene mai cancellata |
| `LIMIT`             | —         | (Ri)verifica solo i primi N file che ne hanno bisogno (utile per un test) |
| `RETRY_ERRORS`      | `false`   | `true` per riprocessare anche le righe riprovabili (`FILE_NOT_FOUND`, `EXTRACTION_FAILED`, `DETECTION_FAILED`, `LOW_CONFIDENCE`) |
| `NO_RESUME`         | `false`   | `true` per ignorare un CSV di output esistente e ripartire da zero |

### Variabili solo d'ambiente

Non sono nella allow-list del `.env` (metterle lì produce un avviso): vanno
passate nell'ambiente del comando.

| Variabile         | Default     | Significato |
|-------------------|-------------|-------------|
| `ALA_DOTENV_FILE` | —           | Usa questo `.env` invece di cercarlo nel repository |
| `ARR_PLAIN_MENU`  | —           | Impostata a qualsiasi valore, forza il menu numerato anche con `whiptail` installato |
| `ARR_TIMEOUT`     | `120`       | Timeout in secondi di ogni richiesta a Radarr/Sonarr |
| `ARR_RETRY_DELAY` | `2`         | Secondi tra due tentativi di una richiesta fallita |
| `ARR_ASSUME_TTY`  | —           | `1` esegue il wizard della fase 1 senza terminale |
| `ARR_LOCALHOST`   | `localhost` | Host che la sonda `/ping` del wizard prova |

Tutti e quattro gli script (orchestratore, fase 1, launcher della fase 2 e
`report.py`) accettano `-h` / `--help`, e quello è l'unico posto dove
argomenti, variabili e codici di uscita sono definiti.

## Verdetti di output (fase 2)

| Verdetto                | Significato | Azione suggerita |
|-------------------------|-------------|------------------|
| `MISTAGGED_IS_ITALIAN`  | L'audio è italiano; il tag era sbagliato | Correggi il tag / mediaInfo, rescan |
| `CONFIRMED_NOT_ITALIAN` | L'audio davvero non è italiano | Riscarica o fai il remux di una traccia italiana |
| `LOW_CONFIDENCE`        | Una lingua è stata nominata ma sotto `MIN_CONFIDENCE`: non decide nulla | Rilancia con un `WHISPER_MODEL` più grande o un altro `SAMPLE_OFFSET_PCT`, oppure con `--retry-errors` |
| `FILE_NOT_FOUND`        | Il percorso dal CSV della fase 1 non è visibile su questa macchina | Monta la libreria, o esegui la fase 2 dove risiedono i file |
| `EXTRACTION_FAILED`     | `ffmpeg` non è riuscito a produrre un campione | Ispeziona il file manualmente |
| `DETECTION_FAILED`      | `faster-whisper` ha sollevato un errore sul campione, o non ha saputo nominare nessuna lingua | Riprova con `RETRY_ERRORS=true`, o con un modello più grande |

`DetectedLanguage` è un codice ISO (`it`, `en`, `de`, …); `Confidence` è la
probabilità di rilevamento lingua del modello (`0.00`–`1.00`).

## Note e limiti

- Viene analizzata la traccia audio che il contenitore marca come **default**
  (altrimenti la prima), e **solo la finestra campionata decide**: un file la
  cui manciata di minuti campionati è musica, o le cui tracce differiscono da
  quella di default, viene giudicato su quello che quella finestra contiene. È
  esattamente per questo che un rilevamento sotto `MIN_CONFIDENCE` viene
  riportato come `LOW_CONFIDENCE` e non come una risposta.
- Un file con traccia di default inglese più una traccia italiana secondaria
  verrà segnalato come `CONFIRMED_NOT_ITALIAN` — cosa che, per "l'audio di
  default non è italiano", è probabilmente corretta, ma è bene saperlo.
- Il rilevamento gira sull'API `detect_language` di faster-whisper con il
  filtro VAD attivo e fino a **due** finestre: la seconda viene provata quando
  la prima resta sotto la soglia di rilevamento, che è ciò che serve a un
  campione che si apre su musica o su un cartello silenzioso. Su una
  `faster-whisper` troppo vecchia per quel metodo si ricade su `transcribe()`.
  Film che si aprono con un lungo tratto senza dialoghi, o che mescolano
  lingue, possono comunque ingannarlo — regola `SAMPLE_SECONDS` /
  `SAMPLE_OFFSET_PCT`, o alza `WHISPER_MODEL`.
- Al primo run il modello viene scaricato da Hugging Face; da lì in poi tutto è
  locale: nessun audio e nessun metadato lascia la tua macchina.

## Sviluppo

Servono `bats-core` (le librerie `bats-support` / `bats-assert` sono già
incluse in `tests/bats/lib`), `shellcheck` e
[`uv`](https://github.com/astral-sh/uv) — `ruff` e `pytest` girano via `uvx`,
così nel progetto non viene installato nulla.

```bash
./scripts/test.sh all      # lint, poi pytest, poi bats
./scripts/test.sh lint     # shellcheck -S warning sugli script + ruff check .
./scripts/test.sh py       # pytest su 3.12 e sul floor 3.9
./scripts/test.sh bats     # la suite bats, forzata su /bin/bash
```

La CI (`.github/workflows/ci.yml`) copre le stesse tre fasi: il job *lint* su
`ubuntu-latest` richiama `scripts/test.sh lint`; i job *bats* (`ubuntu-latest`
e `macos-latest`) e *pytest* (matrice `ubuntu-latest` × `macos-latest` per
Python `3.9`, `3.12` e `3.13`) lanciano i comandi direttamente, perché hanno
bisogno della matrice di sistemi e interpreti; lo script locale copre `3.9` e
`3.12`, la CI aggiunge `3.13`.

**Il gate su bash 3.2.** Sia in locale sia in CI la suite bats gira con
`PATH="/bin:/usr/bin:$PATH"` e `BASH_UNDER_TEST=/bin/bash`, così su macOS gli
script vengono eseguiti dalla bash 3.2 di sistema e non da quella 5.x di
Homebrew; un test asserisce di essere davvero su bash 3 quando gira su macOS, e
un altro cerca nei sorgenti i costrutti che richiedono bash 4 (`mapfile`,
`declare -A`, `${var,,}`, …) e fallisce se ne trova.

**Come funzionano i fake.** Nessun test tocca la rete, `ffmpeg` o whisper: la
suite bats mette in testa al `PATH` degli shim per `curl`, `jq`, `ffmpeg`,
`ffprobe`, `python3`, `df`, `uname`, `whiptail`, `apt` e un `recorder`
generico, tutti pilotati da
variabili d'ambiente, e affianca un finto Radarr/Sonarr HTTP che risponde dai
fixture JSON in `tests/bats/fixtures`. Sul lato Python, un pacchetto
`faster_whisper` stub su `PYTHONPATH` legge il marcatore che lo shim di
`ffmpeg` ha scritto nel "campione" e risponde da uno script JSON, così un test
dichiara che lingua "è" un dato file senza decodificare un byte di audio.

Le decisioni architetturali sono in [`docs/adr/`](docs/adr/); le modifiche
visibili all'utente in [`CHANGELOG.md`](CHANGELOG.md).

## Adattare a un'altra lingua

- **Fase 1:** modifica `ITALIAN_REGEX` in `scan/find-missing-italian-audio.sh`.
- **Fase 2:** modifica `is_italian()` in `verify/verify_audio_language.py` e le
  stringhe dei verdetti in `verify/audit_common.py`.

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
   - `LOW_CONFIDENCE` — a language was named, but below `MIN_CONFIDENCE`: it
     decides nothing and needs another run.

## Repository layout

```
arr-language-audit/
├── arr-language-audit.sh         interactive orchestrator (recommended entry point)
├── README.md
├── CHANGELOG.md                  user-visible changes (Keep a Changelog)
├── LICENSE                       MIT
├── .gitignore
├── .env.example                  config template (copy to .env)
├── pyproject.toml                ruff and pytest configuration
├── lib/
│   └── common.sh                 shared helpers: .env, logging, *arr curl, Python discovery
├── scan/
│   └── find-missing-italian-audio.sh     phase 1 (bash + curl + jq)
├── verify/
│   ├── verify-audio-language.sh          phase 2 launcher / pre-flight checks
│   ├── verify_audio_language.py          phase 2 worker (ffmpeg + faster-whisper)
│   ├── audit_common.py                   shared constants (verdicts, columns, paths)
│   ├── report.py                         phase 2 CSV -> HTML report (+ optional viewer)
│   └── requirements.txt                  the phase 2 dependency (faster-whisper, pinned)
├── scripts/
│   └── test.sh                   one entry point for the checks, used by CI too
├── tests/
│   ├── bats/                     bash suite (bats-core), fixtures and PATH shims
│   ├── fakes/                    fake Radarr/Sonarr and stub faster_whisper package
│   └── python/                   pytest suite
├── docs/
│   ├── adr/                      architecture decision records (MADR format)
│   └── audit/                    audit notes and the test strategy
├── .github/workflows/ci.yml      lint + bats + pytest on Linux and macOS
└── reports/                      output (CSV, cache, HTML) — created on first run, git-ignored
```

## Requirements

**Phase 1:** `bash` ≥ 3.2, `curl`, `jq` ≥ 1.6, and network access to your
Radarr/Sonarr API.

Those floors exist because the toolkit has to run on a stock macOS install:
`bash` ≥ 3.2 is the `/bin/bash` Apple ships, and Python ≥ 3.9 is its system
interpreter. See
[docs/adr/0001-compatibility-floors.md](docs/adr/0001-compatibility-floors.md).

**Phase 2:** everything above plus:

- `ffmpeg` / `ffprobe`
- `python3` ≥ 3.9 with `pip`
- the `faster-whisper` Python package, installed by you from
  `verify/requirements.txt` (the script never installs anything on its own; it
  prints the exact commands and stops)
- **direct filesystem access to the actual media files.** Phase 2 reads the
  file paths from the phase 1 CSV and opens those files to sample their audio.
  The Radarr/Sonarr API alone is **not enough** for phase 2 — the machine
  running it must see the same paths (same host, or the library mounted at the
  same location, e.g. over NFS/SMB).
- enough free disk space in the temp directory for one short WAV sample at a
  time (default guard: 500 MB, see `MIN_FREE_SPACE_MB`).

The phase 2 interpreter is picked in this order: `PYTHON_BIN` if it can import
`faster_whisper`; then the local virtual environment at `verify/venv`; then the
system `python3`. A `PYTHON_BIN` that cannot import the package is reported and
ignored, never used silently. The chosen interpreter must be Python ≥ 3.9, and
that is checked in the pre-flight rather than halfway through a multi-hour scan.

On Debian/Ubuntu, where the system Python is externally managed (PEP 668), the
launcher also checks that `python3 -m venv` actually works and, if `ensurepip`
is missing, tells you the right `pythonX.Y-venv` apt package to install.

**First phase 2 run:** `faster-whisper` downloads the selected model from
Hugging Face and caches it. That is the only moment the network is needed —
from the second run on, phase 2 works entirely offline. Changing
`WHISPER_MODEL` downloads that model once.

## Quickstart

The easiest way is the interactive orchestrator: it drives both phases and
the report from one menu, always passing explicit paths, so it does not
matter which directory you run it from.

```bash
cd arr-language-audit
./arr-language-audit.sh
```

On launch it runs a pre-flight: it loads `.env`, checks the tools each phase
needs, asks the phase 2 launcher (`verify-audio-language.sh --check`) whether
its environment is ready, and queries Radarr/Sonarr
(`/api/v3/system/status`) so the header shows what is connected, which version,
and — under *Connection details* — the root folders with their accessibility
and free space, and it suggests the next sensible step (tagged *(recommended)*
and pre-selected). Menu: *Scan (phase 1)* → *Verify (phase 2)* → *Build /
Serve HTML report* → *Run full pipeline* → *Set up phase 2* (creates
`verify/venv` and installs `verify/requirements.txt`, with confirmation), plus
*Connection details*, *Reconfigure (.env)*, *Reset reports* (deletes the
CSV/HTML/cache files in `reports/` to start over, with confirmation) and
*About*. It uses `whiptail` when available (ncurses dialogs) and falls back to
a plain numbered prompt — `ARR_PLAIN_MENU`, set to anything, forces the plain
menu even when `whiptail` is installed. All output lands in `reports/`.

When phase 1 exits 2 (an enabled app could not be reached) or phase 2 exits 3
(no file could be verified), the orchestrator says so on screen and leaves the
previous report alone rather than letting the failure pass unnoticed. The API
keys are never exported: `ffmpeg`, whisper and the report run with
`RADARR_API_KEY` / `SONARR_API_KEY` removed from their environment.

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
one, and offers to save everything to a `.env` file in the repo root (written
with permissions 600). If nothing is detected it asks for the full URL
instead. Input is validated: the URL must be `http://` or `https://` with no
whitespace, and the API key letters and digits only, so a paste that picked up
quotes or blanks is refused at the prompt instead of on every run.

Prefer to configure it by hand:

```bash
cp .env.example .env
# edit .env: set RADARR_URL / RADARR_API_KEY / SONARR_URL / SONARR_API_KEY
./scan/find-missing-italian-audio.sh
```

Output: `reports/missing-italian-audio.csv` with columns
`App,Title,Year,Episode,AudioLanguages,Path`. With no findings the file is
still written, with its header row and nothing else.

The report is built in `<OUTPUT_CSV>.tmp.<pid>` and moved into place at the
end, so a reader never sees a partial file. Being a rename, it gives the report
a new file's permissions rather than those of the one it replaces.

Exit codes:

| Code  | Meaning |
|-------|---------|
| `0`   | the scan completed (with or without findings); the report was replaced |
| `1`   | missing dependency (`jq` / `curl`) or bad arguments |
| `2`   | an enabled app could not be listed after retries: the temporary file is discarded, so a previous report survives untouched |

Stale tags? Force Radarr/Sonarr to re-read every file from disk first:

```bash
FORCE_RESCAN=true ./scan/find-missing-italian-audio.sh
```

`FORCE_RESCAN=true` implies `REFRESH=true`: a rescan can change the tags
without changing a series' signature, and a cache hit would hide exactly what
the rescan was asked for. The rescan is waited out for at most
`RESCAN_TIMEOUT` seconds (default 900), polled every `RESCAN_POLL_INTERVAL`
seconds (default 5); a rescan that reports *failed*, *aborted*, *cancelled* or
*orphaned* is not waited out at all — the scan warns and carries on.

**Sonarr cache.** Sonarr is queried once per series (episodes with the file
embedded in the response). A `missing-italian-audio.cache.json` file is
written next to the CSV, recording a per-series signature (file count + size
on disk as reported by Sonarr) and the rows that series produced. On the next
run a series whose signature is unchanged is not re-fetched: its rows are
re-emitted from the cache.

The cache is at version 2: it carries a `__meta` block with its schema version
and the Italian regex it was built with. A cache written by another version, or
with another regex, is discarded and rebuilt — so changing `ITALIAN_REGEX` does
not leave rows behind that were computed with the previous one. Force a full
re-scan with:

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

To check the environment only, verifying nothing:

```bash
./verify/verify-audio-language.sh --check
```

`--check` is accepted in any position, so
`./verify/verify-audio-language.sh in.csv --check` checks the environment for
that input without running anything. It is the same question the orchestrator
asks: if the launcher says phase 2 is ready, it is.

If a dependency is missing the script prints the exact install command and
exits without changing anything. A typical first-time setup on Debian/Ubuntu:

```bash
sudo apt install -y ffmpeg python3-venv
python3 -m venv verify/venv
"verify/venv/bin/pip" install --upgrade pip
"verify/venv/bin/pip" install -r verify/requirements.txt
./verify/verify-audio-language.sh          # detects and uses verify/venv automatically
```

The run is resumable: stop it any time and run it again — files already
verified in the output CSV are reused. Rows are matched on `(path, episode)`,
not on the path alone: a single file holding a double episode is two Sonarr
rows sharing one path, and each of them keeps its own verdict.

A file is **re-verified automatically** when its size or mtime changed since
the last run (you replaced, re-encoded or re-downloaded it), even though its
path is unchanged. Rows written by older versions have no
`FileSize`/`FileMtime` and are reused as-is until verified again. An error row
carrying no signature (typically a `FILE_NOT_FOUND` from a run where the share
was not mounted) is retried as soon as the file is visible again, and is never
stamped with a signature it was not verified against.

A row whose file is no longer listed by phase 1 is **dropped** if that file
also changed on disk (you fixed it -- the old verdict would be wrong), and
**kept** otherwise (a narrower scan scope from `SKIP_*` or a downed app, or a
missing file). An episode that phase 1 relabels keeps its verdict: the row
under the old label is superseded and dropped, and the verdict moves to the new
one as long as the file's signature is unchanged — renaming an episode never
costs a re-listen and never leaves the same file in the report twice.

`LIMIT` (an environment variable of the launcher; the worker takes `--limit`)
caps how many files are (re)verified in one run; the
rows it cuts keep the verdict they already had, so a limited run never empties
out the report. To really start from scratch use "Reset reports" in the
orchestrator, or `NO_RESUME=true` to regenerate just this CSV. To retry the
retryable rows — `FILE_NOT_FOUND`, `EXTRACTION_FAILED`, `DETECTION_FAILED` and
`LOW_CONFIDENCE` too — use `RETRY_ERRORS=true`.

Custom paths:

```bash
./verify/verify-audio-language.sh /path/to/input.csv /path/to/output.csv
```

Worker exit codes:

| Code  | Meaning |
|-------|---------|
| `0`   | finished (including "nothing new to verify") |
| `1`   | configuration, input, output path or disk-space problem, or the model could not be loaded (the previous output CSV is untouched) |
| `2`   | usage error: an unknown flag or a bad value (argparse) |
| `3`   | every file this run tried to verify errored |
| `130` | interrupted (Ctrl-C); the CSV written so far stays valid |

The launcher returns `1` for its own usage errors and for a failed pre-flight,
and otherwise passes the worker's codes through unchanged. `2` always comes from
the worker: calling it by hand with a bad flag, or giving the launcher a
non-numeric `LIMIT`, which is forwarded as `--limit` and rejected by argparse.

### Phase 2 report (HTML)

The CSV is the canonical output. `verify/report.py` turns it into a single
self-contained HTML file (inline CSS + JS, no external resources, works
offline) that is easier to browse: filter chips per verdict, free-text
search on title/path, sortable columns, a summary bar, and "copy path" /
"copy visible paths" buttons to build a redownload list. Standard library
only, no extra dependencies.

To stay light on big libraries the table stops at 2000 rows and offers a
*Show all N rows* button to render the rest.

```bash
./verify/report.py                       # reads reports/verified-language-results.csv
                                         # writes reports/verified-language-results.html
./verify/report.py results.csv -o out.html
```

To consult it from another machine, add `--serve`: it starts a small
webserver, prints the URL, and waits — press **Enter** to stop it. Nothing
stays running afterwards (the `.html` file itself is kept, like the CSV).

```bash
./verify/report.py --serve                      # binds 127.0.0.1 on a free port
./verify/report.py --serve --host 0.0.0.0       # exposed on the LAN
./verify/report.py --serve --port 8080
```

The default bind is **`127.0.0.1`**: unasked, the report is not reachable from
another machine. Exposing it on the LAN takes `--host 0.0.0.0`, and the
orchestrator asks before doing that.

The served URL carries a random access token (`?k=...`); requests without a
valid token get `403`. Responses are sent with `Cache-Control: no-store`,
`Referrer-Policy: no-referrer` and `X-Content-Type-Options: nosniff`. Since the
report contains full filesystem paths, treat the URL as sensitive anyway — on
an untrusted network prefer an SSH tunnel over the default bind, or drop the
token check entirely with `--no-token` if you know the port is safe.

| Option        | Default        | Meaning |
|---------------|----------------|---------|
| `-o, --output`| CSV path `.html` | Output HTML path |
| `--serve`     | off            | Serve the HTML and wait for Enter |
| `--host`      | `127.0.0.1`    | Bind address when serving (`0.0.0.0` to expose on the LAN) |
| `--port`      | `0` (free port)| Bind port when serving |
| `--no-token`  | off            | Serve without the `?k=` access check |

It exits `0` once the HTML is written (and, with `--serve`, the server was
stopped cleanly), `1` when the input CSV is missing or unreadable, or the
requested port cannot be bound.

## Configuration

### The `.env` file

The file is looked up, **in this order**, at `<repo>/.env` and then at
`<repo>/scan/.env`; the first match wins. The **current working directory is
not read**: running the audit from a directory someone else can write must not
change what it does. `ALA_DOTENV_FILE`, when set and non-empty, replaces that
search with the file it names, and reports "no .env" rather than falling back
if that file is absent.

The file is **parsed, never executed**: no `source`, no `eval`. A `.env` is
frequently world-readable and sometimes shared, and sourcing it would hand
whoever can write it arbitrary code execution as the user running the audit.
Consequently:

- the format is `KEY=value`, one per line; blank lines and `#` comments are
  skipped, and indentation is allowed;
- a malformed line is reported (by line number, never by content: it can still
  hold most of an API key) and ignored;
- one pair of matching surrounding quotes is removed from the value, and
  nothing else about it is interpreted: **values are not shell-expanded** —
  `$HOME`, `$(...)` and backquotes stay literal text;
- only allow-listed keys are set; any other key is reported and dropped, so a
  `.env` is not a way to reach `PATH`, `LD_PRELOAD` or `IFS`;
- the loader exports nothing: a caller that wants a child process to see a
  value exports it itself.

**Precedence:** command-line flag > an already-set, non-empty environment
variable > `.env` > default. So `LIMIT=5 ./verify/verify-audio-language.sh`
beats what `.env` says, and `--refresh` beats both.

### Phase 1 environment variables

| Variable         | Default                  | Meaning |
|------------------|--------------------------|---------|
| `RADARR_URL`     | `http://localhost:7878`  | Radarr base URL |
| `RADARR_API_KEY` | —                        | Radarr API key |
| `SONARR_URL`     | `http://localhost:8989`  | Sonarr base URL |
| `SONARR_API_KEY` | —                        | Sonarr API key |
| `SKIP_RADARR`    | `false`                  | `true` to skip Radarr entirely |
| `SKIP_SONARR`    | `false`                  | `true` to skip Sonarr entirely |
| `FORCE_RESCAN`   | `false`                  | `true` to run `RescanMovie` / `RescanSeries` before reading `mediaInfo`; implies `REFRESH=true` |
| `RESCAN_TIMEOUT` | `900`                    | Seconds to wait for a rescan command to finish |
| `RESCAN_POLL_INTERVAL` | `5`                | Seconds between two rescan status polls |
| `REFRESH`        | `false`                  | `true` to ignore the Sonarr cache and re-fetch every series (same as `--refresh`) |

The first positional argument overrides the output CSV path:
`./scan/find-missing-italian-audio.sh /tmp/report.csv`. The `--refresh` flag
ignores the Sonarr cache for that run.

### Phase 2 environment variables

| Variable            | Default   | Meaning |
|---------------------|-----------|---------|
| `PYTHON_BIN`        | —         | Interpreter to run phase 2 with; one that cannot import `faster_whisper` is reported and ignored |
| `WHISPER_MODEL`     | `small`   | `tiny` \| `base` \| `small` \| `medium` — bigger is more accurate and slower |
| `WHISPER_THREADS`   | all cores | CPU threads for the model |
| `SAMPLE_SECONDS`    | `60`      | Length of the audio sample analyzed per file |
| `SAMPLE_OFFSET_PCT` | `25`      | Where to start sampling, as a percentage of total duration (skips intros) |
| `MIN_CONFIDENCE`    | `0.6`     | `0` to `1`: a detection below it becomes `LOW_CONFIDENCE` |
| `MIN_FREE_SPACE_MB` | `500`     | Minimum free space required in the temp directory |
| `TEMP_DIR`          | system temp | **Parent** directory for the samples: the run creates its own private `lang-check-*` directory inside it and removes only that one. The directory you point it at is never deleted |
| `LIMIT`             | —         | Only (re)verify the first N files that need it (useful for a test run) |
| `RETRY_ERRORS`      | `false`   | `true` to also reprocess retryable rows (`FILE_NOT_FOUND`, `EXTRACTION_FAILED`, `DETECTION_FAILED`, `LOW_CONFIDENCE`) |
| `NO_RESUME`         | `false`   | `true` to ignore an existing output CSV and start fresh |

### Environment-only variables

These are not on the `.env` allow-list (putting them there produces a warning):
pass them in the command's environment.

| Variable          | Default     | Meaning |
|-------------------|-------------|---------|
| `ALA_DOTENV_FILE` | —           | Read this `.env` instead of searching the repository |
| `ARR_PLAIN_MENU`  | —           | Set to anything, forces the plain numbered menu even when `whiptail` is installed |
| `ARR_TIMEOUT`     | `120`       | Timeout, in seconds, of each Radarr/Sonarr request |
| `ARR_RETRY_DELAY` | `2`         | Seconds between two attempts of a failed request |
| `ARR_ASSUME_TTY`  | —           | `1` runs the phase 1 wizard without a terminal |
| `ARR_LOCALHOST`   | `localhost` | The host the wizard's `/ping` probe tries |

All four scripts (the orchestrator, phase 1, the phase 2 launcher and
`report.py`) accept `-h` / `--help`, and that is the single place where their
arguments, variables and exit codes are defined.

## Output verdicts (phase 2)

| Verdict                 | Meaning | Suggested action |
|-------------------------|---------|------------------|
| `MISTAGGED_IS_ITALIAN`  | Audio is Italian; the tag was wrong | Fix the tag / mediaInfo, rescan |
| `CONFIRMED_NOT_ITALIAN` | Audio really is not Italian | Redownload or remux an Italian track |
| `LOW_CONFIDENCE`        | A language was named but below `MIN_CONFIDENCE`, so it decides nothing | Re-run with a bigger `WHISPER_MODEL` or a different `SAMPLE_OFFSET_PCT`, or with `--retry-errors` |
| `FILE_NOT_FOUND`        | Path from the phase 1 CSV is not visible on this machine | Mount the library, or run phase 2 where the files live |
| `EXTRACTION_FAILED`     | `ffmpeg` could not produce a sample | Inspect the file manually |
| `DETECTION_FAILED`      | `faster-whisper` raised on the sample, or could not name a language at all | Retry with `RETRY_ERRORS=true`, or a larger model |

`DetectedLanguage` is an ISO code (`it`, `en`, `de`, …); `Confidence` is the
model's language-detection probability (`0.00`–`1.00`).

## Notes and limitations

- What is listened to is the audio stream the container marks as **default**
  (else the first one), and **only the sampled window decides**: a file whose
  sampled minutes are music, or whose tracks differ from the default one, is
  judged on what that window contains. That is precisely why a detection below
  `MIN_CONFIDENCE` is reported as `LOW_CONFIDENCE` rather than as an answer.
- A file with an English default track plus a secondary Italian track will be
  reported as `CONFIRMED_NOT_ITALIAN` — which for "the default audio is not
  Italian" is arguably correct, but worth knowing.
- Detection runs through faster-whisper's `detect_language` API with the VAD
  filter on and up to **two** windows: the second is tried when the first comes
  back under the detection threshold, which is what a sample opening on music
  or on a silent title card needs. On a `faster-whisper` too old for that
  method it falls back to `transcribe()`. Films that open with a long
  non-dialogue stretch, or that mix languages, can still fool it — adjust
  `SAMPLE_SECONDS` / `SAMPLE_OFFSET_PCT`, or bump `WHISPER_MODEL`.
- The first run downloads the model from Hugging Face; from then on everything
  is local: no audio and no metadata leave your machine.

## Development

You need `bats-core` (the `bats-support` / `bats-assert` libraries are already
vendored in `tests/bats/lib`), `shellcheck` and
[`uv`](https://github.com/astral-sh/uv) — `ruff` and `pytest` run through
`uvx`, so nothing is installed into the project.

```bash
./scripts/test.sh all      # lint, then pytest, then bats
./scripts/test.sh lint     # shellcheck -S warning over the scripts + ruff check .
./scripts/test.sh py       # pytest on 3.12 and on the 3.9 floor
./scripts/test.sh bats     # the bats suite, forced onto /bin/bash
```

CI (`.github/workflows/ci.yml`) covers the same three stages: the *lint* job
on `ubuntu-latest` calls `scripts/test.sh lint`; the *bats* job (`ubuntu-latest`
and `macos-latest`) and the *pytest* job (`ubuntu-latest` × `macos-latest`
matrix for Python `3.9`, `3.12` and `3.13`) run their commands inline because
they need the OS and interpreter matrix; the local script covers `3.9` and
`3.12`, CI adds `3.13`.

**The bash 3.2 gate.** Locally and in CI the bats suite runs with
`PATH="/bin:/usr/bin:$PATH"` and `BASH_UNDER_TEST=/bin/bash`, so on macOS the
scripts are executed by the system bash 3.2 and not by Homebrew's 5.x; one test
asserts it really is on bash 3 when running on macOS, and another greps the
sources for constructs that need bash 4 (`mapfile`, `declare -A`, `${var,,}`, …)
and fails if it finds any.

**How the fakes work.** No test touches the network, `ffmpeg` or whisper: the
bats suite puts shims for `curl`, `jq`, `ffmpeg`, `ffprobe`, `python3`, `df`,
`uname`, `whiptail`, `apt` and a generic `recorder` at the head of `PATH`, all
driven purely by
environment variables, next to a fake Radarr/Sonarr HTTP server answering from
the JSON fixtures in `tests/bats/fixtures`. On the Python side, a stub
`faster_whisper` package on `PYTHONPATH` reads the marker the `ffmpeg` shim
wrote into the "sample" and answers from a JSON script, so a test declares what
language a given file "is" without decoding a byte of audio.

Architecture decisions live in [`docs/adr/`](docs/adr/); user-visible changes in
[`CHANGELOG.md`](CHANGELOG.md).

## Adapting to another language

- **Phase 1:** change `ITALIAN_REGEX` in `scan/find-missing-italian-audio.sh`.
- **Phase 2:** change `is_italian()` in `verify/verify_audio_language.py` and
  the verdict strings in `verify/audit_common.py`.

## License

[MIT](LICENSE) - 2026 Giovanni Solone
