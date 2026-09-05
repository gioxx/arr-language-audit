# arr-language-audit

🇮🇹 **Italiano** (questa sezione) · 🇬🇧 [**English version** ↓](#english)

Toolkit per controllare l'audio italiano nelle librerie **Radarr** e **Sonarr**:
seleziona i file dai tag delle API, analizza un campione audio in locale e
produce **CSV riprendibili e un report HTML interattivo**. L'orchestratore
guida configurazione, scansione, verifica e consultazione; ogni fase è anche
eseguibile da riga di comando.

Funziona su Linux e macOS, con Bash ≥ 3.2 e Python ≥ 3.9. I file multimediali
vengono letti per il campionamento; correzioni dei tag, remux e download
restano operazioni manuali. CSV, cache e HTML vengono invece creati o aggiornati.

**Il verdetto riguarda il campione della traccia selezionata**, non tutte le
tracce del file. Un tag italiano già presente esclude il file dalla fase 1:
questa pipeline non verifica che ogni tag italiano della libreria sia corretto.
Le rilevazioni sotto soglia restano `LOW_CONFIDENCE`.

[Avvio rapido](#avvio-rapido) · [Prerequisiti](#prerequisiti) ·
[Configurazione](#configurazione) · [Verdetti](#verdetti-di-output-fase-2) ·
[Problemi frequenti](#problemi-frequenti) · [Limiti](#note-e-limiti) ·
[Sviluppo e test](#sviluppo)

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
   nessun servizio esterno) per stimare la lingua del campione. Una lingua
   rilevata con probabilità almeno pari a `MIN_CONFIDENCE` produce
   `MISTAGGED_IS_ITALIAN` oppure `CONFIRMED_NOT_ITALIAN`; sotto soglia produce
   `LOW_CONFIDENCE`. I problemi di lettura, estrazione o rilevamento hanno
   verdetti distinti, descritti nella [tabella completa](#verdetti-di-output-fase-2).

| Passaggio | Input | Output |
|---|---|---|
| Scansione API | Radarr e/o Sonarr configurati | `reports/missing-italian-audio.csv` e cache Sonarr |
| Verifica locale | CSV della fase 1 e media accessibili con gli stessi percorsi | `reports/verified-language-results.csv` |
| Report | CSV della fase 2 | `reports/verified-language-results.html`, consultabile offline |

Una scansione API incompleta conserva gli output precedenti e ferma la
pipeline. La verifica riprende dai risultati già disponibili e conserva i
verdetti pendenti su interruzione controllata. Le garanzie e i limiti di
scrittura sono descritti nelle singole fasi.

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
│   ├── python/                   regressioni pytest con dipendenze simulate
│   ├── integration/              contratto con faster-whisper e decoder reali, senza modello
│   └── report-ui/                interazioni JavaScript del report (Node.js + jsdom)
├── docs/
│   ├── adr/                      decisioni architetturali (formato MADR)
│   └── audit/                    note dell'audit e strategia di test
├── .github/workflows/ci.yml      lint, Bash/Python Linux/macOS, report e contratto audio
└── reports/                      output (CSV, cache, HTML) — creata al primo run, git-ignored
```

## Prerequisiti

**Fase 1:** `bash` ≥ 3.2, `curl`, `jq` ≥ 1.6 e accesso di rete alle API di
Radarr/Sonarr.

Bash 3.2 mantiene la compatibilità con `/bin/bash` di macOS. Python 3.9 è
il minimo supportato dal codice: non implica che Python e tutte le dipendenze
siano già installati. Il Python Apple dipende dagli strumenti Xcode/Command
Line Tools; per la fase 2 serve un interprete utilizzabile con le dipendenze. Vedi
[docs/adr/0001-compatibility-floors.md](docs/adr/0001-compatibility-floors.md).

**Fase 2:** Bash ≥ 3.2 per il launcher, più:

- `ffmpeg` / `ffprobe`
- un interprete Python ≥ 3.9; `pip` serve per installare le dipendenze,
  non è richiesto nel Python di sistema se l'ambiente scelto è già pronto
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

Partendo da un CSV già generato, la fase 2 non richiede accesso alle API,
chiavi Arr, `curl` o `jq`. **Solo report:** da un CSV della fase 2 bastano
Python ≥ 3.9 e la libreria standard; non servono ffmpeg, Whisper o Node.js.

L'interprete della fase 2 viene scelto in questo ordine: `PYTHON_BIN`, se
riesce a importare `faster_whisper`; poi il virtual environment locale
`verify/venv`; poi il `python3` di sistema. Un `PYTHON_BIN` che non importa il
pacchetto viene segnalato e ignorato, non usato in silenzio. L'interprete
scelto deve essere Python ≥ 3.9: la verifica avviene nei controlli pre-volo,
non a metà di una scansione da ore.

Su Debian/Ubuntu, dove il Python di sistema è "externally managed" (PEP 668), il
launcher verifica anche che `python3 -m venv` funzioni davvero e, se manca
`ensurepip`, ti indica il pacchetto apt `pythonX.Y-venv` corretto da installare.

**Modello:** al primo utilizzo `faster-whisper` scarica da Hugging Face i pesi
del modello scelto e li conserva in cache. I pesi devono quindi essere
disponibili prima di lavorare senza rete; un modello diverso può richiedere
un nuovo download. Il riconoscimento avviene in locale e il toolkit non invia
campioni audio a servizi di trascrizione. Le richieste alle API Arr e il
download delle dipendenze sono attività di rete separate.

## Avvio rapido

Partendo dalla radice del checkout, configura le sole applicazioni che usi:

```bash
cp .env.example .env
# Imposta URL e API key; usa SKIP_RADARR=true o SKIP_SONARR=true per l'app assente.
./scan/find-missing-italian-audio.sh
```

Questo primo controllo richiede solo le dipendenze della fase 1. Per verificare
l'audio installa anche quelle della fase 2, tramite *Set up phase 2* nel menu
o i [comandi di setup](#fase-2--verifica-cosa-viene-davvero-parlato), poi prova:

```bash
./verify/verify-audio-language.sh --check
LIMIT=5 ./verify/verify-audio-language.sh
./verify/report.py
```

`LIMIT=5` verifica al massimo cinque righe pianificate e conserva i risultati
precedenti delle altre. Apri `reports/verified-language-results.html` per
consultarle; rilancia il launcher senza `LIMIT` per proseguire.

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

Se la fase 1 esce con 2 (richiesta API fallita o payload invalido) o la fase 2 esce con 3
(nessun file verificato con successo), l'orchestratore lo dice a schermo e
lascia intatto il report HTML precedente invece di far passare l'errore in silenzio.
La pipeline si ferma anche quando una fase viene annullata o restituisce un
errore; non usa i CSV precedenti per completare le fasi successive.
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

Il report viene costruito in `<OUTPUT_CSV>.tmp.<random>` e spostato al suo posto
alla fine, così nessun lettore vede un file parziale. Il file temporaneo è
creato con `mktemp` e permessi `0600`, mantenuti anche dopo la sostituzione.

Codici di uscita:

| Codice | Significato |
|--------|-------------|
| `0`    | scansione completata (con o senza risultati); il report è stato sostituito |
| `1`    | dipendenza mancante (`jq` / `curl`), argomenti errati o destinazione di output rifiutata/non scrivibile |
| `2`    | una richiesta API (anche dettagli episodio/file) fallisce dopo i retry o restituisce un payload invalido; CSV e cache precedenti restano intatti |

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

La cache è alla versione 3: `__meta` registra schema, regex italiana e URL
Sonarr. Ogni serie include anche titolo, percorso, ID TVDB, data di aggiunta e percorsi
originali di tutti i media (anche quelli con tag italiano):
cambiare istanza, rinominare o sostituire una serie invalida le vecchie righe.
Le destinazioni di CSV e cache vengono confrontate con i percorsi dei media
prima della pubblicazione, anche nei run da cache. Cache precedenti o
malformate vengono ricostruite; statistiche assenti non
producono cache hit. CSV e cache vengono pubblicati solo dopo una scansione
completa: anche errori nei dettagli degli episodi o risposte JSON non valide
fanno uscire con `2`, mantenendo i report precedenti. Per forzare una scansione completa:

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
`./verify/verify-audio-language.sh in.csv --check` controlla l'ambiente senza
avviare una verifica. Controlla strumenti, versione di Python e importabilità
di `faster_whisper`; non controlla il CSV, lo spazio disponibile, i valori
numerici del worker o il caricamento dei pesi. L'orchestratore usa lo stesso
controllo per indicare la disponibilità delle dipendenze.

Se manca una dipendenza lo script stampa il comando di installazione esatto ed
esce senza cambiare nulla. Un tipico primo setup su Debian/Ubuntu:

```bash
sudo apt install -y ffmpeg python3-venv
python3 -m venv verify/venv
"verify/venv/bin/pip" install --upgrade pip
"verify/venv/bin/pip" install -r verify/requirements.txt
./verify/verify-audio-language.sh          # rileva e usa verify/venv automaticamente
```

I CSV vengono validati prima di sostituire qualsiasi output. L'output non
può coincidere con il CSV di input o con un media elencato, nemmeno tramite
link simbolico o hardlink; i percorsi conservano gli spazi nei nomi dei file.
Le nuove firme `FileMtime` mantengono la precisione subsecondo del filesystem;
le firme precedenti restano confrontabili con la precisione originale.
Su Ctrl-C o spazio insufficiente rilevato dal worker, i vecchi verdetti ancora
in attesa di verifica vengono conservati. Un arresto forzato (`SIGKILL`), la
perdita di alimentazione o un guasto I/O durante l'append restano fuori da
questa garanzia.

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
falso), altrimenti viene **mantenuta** (scan con scope ridotto per `SKIP_*`,
input personalizzato o file sparito). Un episodio che la fase 1 rietichetta
conserva il suo verdetto: la riga con la vecchia etichetta viene sostituita e
rimossa, e il verdetto si sposta su quella nuova finché la firma del file non
cambia — rinominare un episodio non costa un nuovo ascolto e non lascia lo
stesso file due volte nel report.

`LIMIT` (variabile d'ambiente del launcher; il worker accetta `--limit`)
limita quante righe vengono (ri)verificate in un run: le
righe che taglia conservano il verdetto che avevano già, quindi un run limitato
non svuota mai il report. Per ripartire davvero da zero usa "Reset reports"
nell'orchestratore, oppure `NO_RESUME=true` per rigenerare solo questo CSV. Per
riprovare le righe riprovabili — `FILE_NOT_FOUND`, `EXTRACTION_FAILED`,
`DETECTION_FAILED` e anche `LOW_CONFIDENCE` — usa `RETRY_ERRORS=true`.

Cambiare `WHISPER_MODEL`, `SAMPLE_SECONDS`, `SAMPLE_OFFSET_PCT` o
`MIN_CONFIDENCE` non invalida da solo i risultati salvati. Per applicare i
nuovi parametri alle righe riprovabili aggiungi `RETRY_ERRORS=true`; per
ricalcolare anche i verdetti definitivi usa un nuovo CSV di output oppure
`NO_RESUME=true` (sostituisce i risultati precedenti).

Il launcher legge `.env` e inoltra le variabili al worker. Per invocare il
worker direttamente scegli un interprete con le dipendenze installate e
passa la configurazione nell'ambiente: il Python non legge `.env`.

```bash
WHISPER_MODEL=medium verify/venv/bin/python verify/verify_audio_language.py \
  --input reports/missing-italian-audio.csv \
  --output reports/verified-language-results.csv --retry-errors --limit 5
```

Percorsi personalizzati:

```bash
./verify/verify-audio-language.sh /percorso/input.csv /percorso/output.csv
```

Codici di uscita del worker:

| Codice | Significato |
|--------|-------------|
| `0`    | terminato (anche quando non c'era niente di nuovo da verificare) |
| `1`    | problema di configurazione, input, percorso di output, spazio disco, oppure il modello non si è caricato |
| `2`    | errore d'uso: flag sconosciuta o valore non valido (argparse) |
| `3`    | ogni file che questo run ha provato a verificare è andato in errore |
| `130`  | interrotto (Ctrl-C); il CSV scritto fino a quel punto resta valido |

Gli errori prima della pubblicazione lasciano il CSV precedente intatto.
Durante il lavoro, un arresto controllato conserva risultati completati e
verdetti precedenti ancora pendenti, come descritto sopra.

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
"Copy filtered paths" per costruire una lista di file da riscaricare. Solo
libreria standard, nessuna dipendenza aggiuntiva.

Filtri e ordinamento sono utilizzabili anche da tastiera. La copia include
tutti i risultati del filtro, anche quelli oltre il limite visualizzato, ed
elimina percorsi duplicati. Se il browser nega gli appunti (ad esempio via
HTTP in LAN), mostra il testo selezionato per copiarlo manualmente. L'HTML è
sostituito atomicamente; CSV malformati e output che coincidono con input o
media elencati vengono rifiutati.

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
fermato correttamente), `1` per CSV mancante/invalido, output rifiutato/non
scrivibile o errore del server. Un errore di bind può avvenire dopo la
scrittura dell'HTML. Argomenti errati (inclusa una porta
fuori da `0..65535`) restituiscono `2`, prima di scrivere l'HTML.

## Configurazione

### Il file `.env`

Lo leggono le tre entrypoint shell: orchestratore, scanner e launcher.
Il worker Python diretto usa ambiente e flag; `report.py` usa i propri
argomenti e non carica `.env`.

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
batte quello che dice `.env`, e `--refresh` batte entrambi. *Reconfigure*
modifica il file attivo, incluso `ALA_DOTENV_FILE` o il fallback `scan/.env`.
Le chiamate API usano `curl -q`: `.curlrc` non viene letto, per evitare URL o
redirect aggiuntivi che ricevano la chiave. Le variabili standard curl per
proxy e certificati restano utilizzabili.

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
ignora la cache Sonarr per quel run. `RESCAN_TIMEOUT` accetta da `0` a
`999999999` secondi; `RESCAN_POLL_INTERVAL` da `1` a `999999999`. Le richieste
HTTP di polling dello stato e le pause rispettano il tempo residuo; il POST
iniziale che avvia il rescan usa invece `ARR_TIMEOUT`.

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
| `LIMIT`             | `0` (illimitato) | (Ri)verifica le prime N righe pianificate; intero non negativo |
| `RETRY_ERRORS`      | `false`   | `true` per riprocessare anche le righe riprovabili (`FILE_NOT_FOUND`, `EXTRACTION_FAILED`, `DETECTION_FAILED`, `LOW_CONFIDENCE`) |
| `NO_RESUME`         | `false`   | `true` per ignorare un CSV di output esistente e ripartire da zero |

### Variabili solo d'ambiente

Non sono nella allow-list del `.env` (metterle lì produce un avviso): vanno
passate nell'ambiente del comando.

| Variabile         | Default     | Significato |
|-------------------|-------------|-------------|
| `ALA_DOTENV_FILE` | —           | Usa questo `.env` invece di cercarlo nel repository |
| `ARR_PLAIN_MENU`  | —           | Impostata a qualsiasi valore, forza il menu numerato anche con `whiptail` installato |
| `ARR_TIMEOUT`     | `120`       | Timeout ordinario delle richieste API; polling rescan e sonde pre-volo applicano limiti propri |
| `ARR_PROBE_TIMEOUT` | `3`       | Timeout di ciascuna sonda dell'orchestratore nei controlli pre-volo |
| `ARR_RETRY_DELAY` | `2`         | Secondi tra due tentativi di una richiesta fallita |
| `ARR_ASSUME_TTY`  | —           | `1` esegue il wizard della fase 1 senza terminale |
| `ARR_LOCALHOST`   | `localhost` | Host che la sonda `/ping` del wizard prova |

Orchestratore, scanner, launcher, worker Python e generatore HTML accettano
`-h` / `--help`. Il launcher usa due argomenti posizionali per input e output;
il worker usa `--input` e `--output`. Le opzioni `--retry-errors`, `--limit`
e `--no-resume` appartengono al worker: con il launcher usa rispettivamente
`RETRY_ERRORS`, `LIMIT` e `NO_RESUME`.

## Verdetti di output (fase 2)

| Verdetto                | Significato | Azione suggerita |
|-------------------------|-------------|------------------|
| `MISTAGGED_IS_ITALIAN`  | Il campione è rilevato come italiano con confidenza sufficiente | Verifica la traccia, poi correggi tag / mediaInfo e fai un rescan |
| `CONFIRMED_NOT_ITALIAN` | Il campione è rilevato come non italiano con confidenza sufficiente | Controlla anche le altre tracce prima di decidere remux o download |
| `LOW_CONFIDENCE`        | Lingua rilevata sotto `MIN_CONFIDENCE`; esito non conclusivo | Cambia modello o punto di campionamento e rilancia con `RETRY_ERRORS=true` |
| `FILE_NOT_FOUND`        | Il percorso dal CSV della fase 1 non è visibile su questa macchina | Monta la libreria, o esegui la fase 2 dove risiedono i file |
| `EXTRACTION_FAILED`     | `ffmpeg` non è riuscito a produrre un campione | Ispeziona il file manualmente |
| `DETECTION_FAILED`      | `faster-whisper` ha sollevato un errore sul campione, o non ha saputo nominare nessuna lingua | Riprova con `RETRY_ERRORS=true`, eventualmente con un modello più grande |

`DetectedLanguage` è un codice ISO (`it`, `en`, `de`, …); `Confidence` è la
probabilità di rilevamento lingua del modello (`0.00`–`1.00`).

## Problemi frequenti

| Sintomo | Controllo e azione |
|---|---|
| Un'app non è configurata o non risponde | Controlla URL, chiave e raggiungibilità dalla macchina che esegue il toolkit; imposta `SKIP_RADARR=true` o `SKIP_SONARR=true` solo per l'app che vuoi escludere |
| La scansione termina con `2` | Leggi la richiesta indicata nell'errore, correggi connessione o risposta API e rilancia; il CSV precedente non rappresenta una nuova scansione riuscita |
| `FILE_NOT_FOUND` su tutti i risultati | Confronta i percorsi CSV con i mount locali: non esiste una conversione automatica dei percorsi Docker/NAS |
| L'ambiente della fase 2 non è pronto | Esegui `./verify/verify-audio-language.sh --check`; installa `verify/requirements.txt` nell'interprete indicato oppure scegli un `PYTHON_BIN` adatto |
| Poco spazio temporaneo | Libera spazio oppure scegli `TEMP_DIR=/percorso/con/spazio`; il worker usa una sottodirectory privata e controlla `MIN_FREE_SPACE_MB` |
| Restano risultati a bassa confidenza | Cambiare il modello da solo non invalida il resume: usa anche `RETRY_ERRORS=true`; `NO_RESUME=true` rigenera tutti i risultati |
| Tag corretti ma risultati della fase 1 invariati | Usa `--refresh` per rileggere Sonarr; `FORCE_RESCAN=true` chiede prima anche il rescan dei file alle API |
| Copia negli appunti non disponibile | Usa il testo selezionato mostrato dal report e copia manualmente con Ctrl+C / Command+C |

## Note e limiti

- Viene analizzata la traccia audio che il contenitore marca come **default**
  (altrimenti la prima), quando `ffprobe` restituisce dati utilizzabili. Se il
  probe fallisce, la scelta della traccia viene lasciata a ffmpeg.
  **Solo la finestra campionata decide**: un file la
  cui manciata di minuti campionati è musica, o le cui tracce differiscono da
  quella di default, viene giudicato su quello che quella finestra contiene. È
  esattamente per questo che un rilevamento sotto `MIN_CONFIDENCE` viene
  riportato come `LOW_CONFIDENCE` e non come una risposta.
- Un file incluso nella fase 1 con traccia di default inglese e una traccia
  italiana secondaria può risultare `CONFIRMED_NOT_ITALIAN`: il campionamento
  non inventaria tutte le tracce. Un file già taggato italiano viene invece
  escluso dalla fase 1, anche se quel tag è errato.
- Il rilevamento gira sull'API `detect_language` di faster-whisper con il
  filtro VAD attivo e fino a **due** finestre: la seconda viene provata quando
  la prima resta sotto la soglia di rilevamento (`0.5`), che è ciò che serve a un
  campione che si apre su musica o su un cartello silenzioso. Su una
  `faster-whisper` troppo vecchia per quel metodo si ricade su `transcribe()`.
  Film che si aprono con un lungo tratto senza dialoghi, o che mescolano
  lingue, possono comunque ingannarlo — regola `SAMPLE_SECONDS` /
  `SAMPLE_OFFSET_PCT`, o alza `WHISPER_MODEL`.
- `MIN_CONFIDENCE` filtra il punteggio del modello, non certifica l'accuratezza.
  I test del repository verificano comportamento e integrazioni; non misurano
  il riconoscimento su una libreria reale.
- CSV e cache vengono sostituiti separatamente. Una scansione completa può
  pubblicare il CSV e segnalare un errore nella scrittura della cache: il CSV
  resta valido e una cache assente o precedente può richiedere un nuovo fetch.

## Sviluppo

Servono `bats-core` (le librerie `bats-support` / `bats-assert` sono già
incluse in `tests/bats/lib`), `shellcheck` e
[`uv`](https://github.com/astral-sh/uv) — `ruff` e `pytest` girano via `uvx`,
senza installare pacchetti Python nel progetto. I test del report richiedono
anche Node.js ≥ 22 e npm: `npm ci` installa solo dipendenze di test in
`tests/report-ui/node_modules`, escluse da Git.

```bash
./scripts/test.sh all      # lint, pytest, bats, report e contratto audio reale
./scripts/test.sh lint     # shellcheck -S warning sugli script + ruff check .
./scripts/test.sh py       # pytest su 3.12 e sul floor 3.9
./scripts/test.sh bats     # la suite bats, forzata su /bin/bash
./scripts/test.sh ui       # interazioni del report in jsdom, senza browser
./scripts/test.sh contract # decoder/API faster-whisper reali, senza pesi del modello
```

La CI (`.github/workflows/ci.yml`) copre le stesse cinque fasi: il job *lint* su
`ubuntu-latest` richiama `scripts/test.sh lint`; i job *bats* (`ubuntu-latest`
e `macos-latest`) e *pytest* (matrice `ubuntu-latest` × `macos-latest` per
Python `3.9`, `3.12` e `3.13`) lanciano i comandi direttamente, perché hanno
bisogno della matrice di sistemi e interpreti; lo script locale copre `3.9` e
`3.12`, la CI aggiunge `3.13`. Il job `report-ui` su Linux esegue
`scripts/test.sh ui`: filtri, ordinamento, copia, errori degli appunti e limite
di righe sono verificati eseguendo il JavaScript generato. Node.js non è
necessario per usare il toolkit o visualizzare il report. Il job
`whisper-contract` su Linux (Python 3.9 e 3.12) installa la dipendenza fissata
in `verify/requirements.txt` e verifica decoder PyAV, array float32 a 16 kHz e
API di rilevamento reali, senza scaricare pesi. Il test sostituisce solo VAD e
output neurale: non misura l'accuratezza del riconoscimento linguistico.

**Il gate su bash 3.2.** Sia in locale sia in CI la suite bats gira con
`PATH="/bin:/usr/bin:$PATH"` e `BASH_UNDER_TEST=/bin/bash`, così su macOS gli
script vengono eseguiti dalla bash 3.2 di sistema e non da quella 5.x di
Homebrew; un test asserisce di essere davvero su bash 3 quando gira su macOS, e
un altro cerca nei sorgenti i costrutti che richiedono bash 4 (`mapfile`,
`declare -A`, `${var,,}`, …) e fallisce se ne trova.

**Come funzionano i fake.** I test non contattano servizi esterni né modelli
reali; i server finti usano solo la rete locale di loopback. Il primo setup
di uv/npm può scaricare gli strumenti di test. La suite bats usa `curl` e
`jq` reali contro un finto Radarr/Sonarr HTTP, con fixture JSON in
`tests/bats/fixtures`. Gli shim di `ffmpeg`, `ffprobe`, `python3`, `df`,
`uname`, `whiptail`, `apt` e `recorder` sono pilotati da variabili d'ambiente.
Nella suite Python standard, un pacchetto
`faster_whisper` stub su `PYTHONPATH` legge il marcatore che lo shim di
`ffmpeg` ha scritto nel "campione" e risponde da uno script JSON, così un test
dichiara che lingua "è" un dato file senza decodificare un byte di audio.

Le decisioni architetturali sono in [`docs/adr/`](docs/adr/); le modifiche
visibili all'utente in [`CHANGELOG.md`](CHANGELOG.md). L'[audit iniziale](docs/audit/2026-09-05-deep-audit.md)
e la [revisione successiva](docs/audit/2026-09-05-pr-follow-up.md) documentano
i difetti riprodotti, le correzioni e i limiti delle verifiche.

## Adattare a un'altra lingua

- **Fase 1:** modifica `ITALIAN_REGEX` in `scan/find-missing-italian-audio.sh`.
- **Fase 2:** modifica `is_italian()` in `verify/verify_audio_language.py`.
- Aggiorna insieme costanti dei verdetti, etichette e filtri del report,
  fixture, test e documentazione; il solo nome del verdetto non cambia la lingua.

Non esiste un'opzione runtime per la lingua obiettivo: è una modifica del
codice. Usa nuovi output o `NO_RESUME=true` per evitare di riusare verdetti
calcolati con il vecchio criterio.

## Licenza

[MIT](LICENSE) - 2026 Giovanni Solone

---

<a id="english"></a>

# arr-language-audit (English)

🇬🇧 **English** (this section) · 🇮🇹 [**Versione italiana** ↑](#arr-language-audit)

A toolkit for checking Italian audio in **Radarr** and **Sonarr** libraries:
select candidates from API tags, analyze an audio sample locally, and produce
**resumable CSV results and an interactive HTML report**. The orchestrator
guides configuration, scanning, verification and reporting; each phase can
also run from the command line.

Runs on Linux and macOS with Bash ≥ 3.2 and Python ≥ 3.9. Media files are
read for sampling; tag corrections, remuxing and downloads remain manual
operations. CSV, cache and HTML outputs are created or updated.

**A verdict describes the sample from the selected stream**, not every audio
track in the file. An existing Italian tag excludes a file from phase 1:
this pipeline does not check whether every Italian tag in a library is correct.
Detections below the confidence threshold remain `LOW_CONFIDENCE`.

[Quickstart](#quickstart) · [Requirements](#requirements) ·
[Configuration](#configuration) · [Verdicts](#output-verdicts-phase-2) ·
[Troubleshooting](#troubleshooting) · [Limitations](#notes-and-limitations) ·
[Development and tests](#development)

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
   no external service) to estimate the sample's language. A detection with
   probability at least `MIN_CONFIDENCE` produces `MISTAGGED_IS_ITALIAN` or
   `CONFIRMED_NOT_ITALIAN`; below that threshold it produces `LOW_CONFIDENCE`.
   Reading, extraction and detection failures have distinct verdicts in the
   [complete table](#output-verdicts-phase-2).

| Step | Input | Output |
|---|---|---|
| API scan | Configured Radarr and/or Sonarr | `reports/missing-italian-audio.csv` and Sonarr cache |
| Local verification | Phase 1 CSV and media accessible at the same paths | `reports/verified-language-results.csv` |
| Report | Phase 2 CSV | `reports/verified-language-results.html`, viewable offline |

An incomplete API scan preserves previous outputs and stops the pipeline.
Verification resumes from existing results and retains pending verdicts on
controlled interruption. Each phase below explains its write guarantees and
limitations.

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
│   ├── python/                   pytest regressions with controlled dependencies
│   ├── integration/              real faster-whisper and decoder contract, without a model
│   └── report-ui/                report JavaScript interactions (Node.js + jsdom)
├── docs/
│   ├── adr/                      architecture decision records (MADR format)
│   └── audit/                    audit notes and the test strategy
├── .github/workflows/ci.yml      lint, Linux/macOS Bash/Python, report and audio contract
└── reports/                      output (CSV, cache, HTML) — created on first run, git-ignored
```

## Requirements

**Phase 1:** `bash` ≥ 3.2, `curl`, `jq` ≥ 1.6, and network access to your
Radarr/Sonarr API.

Bash 3.2 keeps compatibility with macOS `/bin/bash`. Python 3.9 is the
minimum supported by the code, not a promise that Python or its dependencies
are preinstalled. Apple's Python depends on Xcode/Command Line Tools; phase 2
needs a usable interpreter with the required packages. See
[docs/adr/0001-compatibility-floors.md](docs/adr/0001-compatibility-floors.md).

**Phase 2:** Bash ≥ 3.2 for the launcher, plus:

- `ffmpeg` / `ffprobe`
- a Python ≥ 3.9 interpreter; `pip` is needed to install dependencies,
  not in the system Python when the selected environment is already ready
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

With an existing input CSV, phase 2 does not require API access, Arr keys,
`curl` or `jq`. **Report only:** given a phase 2 CSV, Python ≥ 3.9 and its
standard library are sufficient; ffmpeg, Whisper and Node.js are not required.

The phase 2 interpreter is picked in this order: `PYTHON_BIN` if it can import
`faster_whisper`; then the local virtual environment at `verify/venv`; then the
system `python3`. A `PYTHON_BIN` that cannot import the package is reported and
ignored, never used silently. The chosen interpreter must be Python ≥ 3.9, and
that is checked in the pre-flight rather than halfway through a multi-hour scan.

On Debian/Ubuntu, where the system Python is externally managed (PEP 668), the
launcher also checks that `python3 -m venv` actually works and, if `ensurepip`
is missing, tells you the right `pythonX.Y-venv` apt package to install.

**Model:** on first use, `faster-whisper` downloads the selected model weights
from Hugging Face and caches them. Weights must therefore be available before
working without a network connection; a different model may require another
download. Recognition runs locally, and the toolkit does not send audio
samples to transcription services. Arr API requests and dependency downloads
are separate network operations.

## Quickstart

From the checkout root, configure the applications you actually use:

```bash
cp .env.example .env
# Set URLs and API keys; use SKIP_RADARR=true or SKIP_SONARR=true for the absent app.
./scan/find-missing-italian-audio.sh
```

This first check needs only the phase 1 dependencies. To verify audio, install
the phase 2 dependencies through *Set up phase 2* in the menu or the
[setup commands](#phase-2--verify-what-is-actually-spoken), then try:

```bash
./verify/verify-audio-language.sh --check
LIMIT=5 ./verify/verify-audio-language.sh
./verify/report.py
```

`LIMIT=5` verifies at most five planned rows and retains previous results for
the others. Open `reports/verified-language-results.html` to inspect them;
run the launcher without `LIMIT` to continue.

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

When phase 1 exits 2 (failed API request or invalid payload) or phase 2 exits 3
(no file could be verified), the orchestrator says so on screen and leaves the
previous HTML report alone rather than letting the failure pass unnoticed.
The pipeline also stops after a failed or cancelled stage, without using older
CSV files for subsequent stages. API keys are never exported: `ffmpeg`, whisper and the report run with
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

The report is built in `<OUTPUT_CSV>.tmp.<random>` and moved into place at the
end, so a reader never sees a partial file. `mktemp` creates the temporary
file with private `0600` permissions, retained when the report is replaced.

Exit codes:

| Code  | Meaning |
|-------|---------|
| `0`   | the scan completed (with or without findings); the report was replaced |
| `1`   | missing dependency (`jq` / `curl`), bad arguments or refused/unwritable output destination |
| `2`   | an API request (including episode/file details) fails after retries or returns an invalid payload; previous CSV and cache stay intact |

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

The cache is at version 3: `__meta` records the schema, Italian regex and
Sonarr URL. Each series also records its title, path, TVDB ID, addition date and original
paths of all media (including Italian-tagged files). Switching instances,
renaming or replacing a series invalidates old rows. Output and cache
destinations are checked against media paths before publication, including
on cached runs. Older or malformed caches are rebuilt; absent statistics never produce
a cache hit. CSV and cache are published only after a complete scan: episode
detail failures and invalid JSON responses also exit `2`, preserving previous
reports. Force a full re-scan with:

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
`./verify/verify-audio-language.sh in.csv --check` checks the environment
without starting verification. It checks tools, the Python version and whether
`faster_whisper` can be imported; it does not check the CSV, free disk space,
worker numeric settings or model-weight loading. The orchestrator uses this
same check to report dependency readiness.

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

CSV inputs are validated before output replacement. The output cannot alias
the input CSV or listed media, including through symlinks or hardlinks; file
paths retain filename whitespace. New `FileMtime` signatures preserve the
filesystem's subsecond precision, while older signatures keep their original
precision. Ctrl-C and disk-space aborts detected by the worker retain previous
verdicts still waiting for verification. Forced termination (`SIGKILL`), power
loss and I/O failures during append are outside that guarantee.

A file is **re-verified automatically** when its size or mtime changed since
the last run (you replaced, re-encoded or re-downloaded it), even though its
path is unchanged. Rows written by older versions have no
`FileSize`/`FileMtime` and are reused as-is until verified again. An error row
carrying no signature (typically a `FILE_NOT_FOUND` from a run where the share
was not mounted) is retried as soon as the file is visible again, and is never
stamped with a signature it was not verified against.

A row whose file is no longer listed by phase 1 is **dropped** if that file
also changed on disk (you fixed it -- the old verdict would be wrong), and
**kept** otherwise (a narrower scan scope from `SKIP_*`, custom input or a
missing file). An episode that phase 1 relabels keeps its verdict: the row
under the old label is superseded and dropped, and the verdict moves to the new
one as long as the file's signature is unchanged — renaming an episode never
costs a re-listen and never leaves the same file in the report twice.

`LIMIT` (an environment variable of the launcher; the worker takes `--limit`)
caps how many rows are (re)verified in one run; the
rows it cuts keep the verdict they already had, so a limited run never empties
out the report. To really start from scratch use "Reset reports" in the
orchestrator, or `NO_RESUME=true` to regenerate just this CSV. To retry the
retryable rows — `FILE_NOT_FOUND`, `EXTRACTION_FAILED`, `DETECTION_FAILED` and
`LOW_CONFIDENCE` too — use `RETRY_ERRORS=true`.

Changing `WHISPER_MODEL`, `SAMPLE_SECONDS`, `SAMPLE_OFFSET_PCT` or
`MIN_CONFIDENCE` alone does not invalidate saved results. To apply new
settings to retryable rows, also set `RETRY_ERRORS=true`; to recalculate
definitive verdicts as well, use a new output CSV or `NO_RESUME=true`
(replaces previous results).

The launcher reads `.env` and forwards settings to the worker. For a direct
worker invocation, choose an interpreter with the dependencies installed and
pass configuration through the environment: the Python worker does not read
`.env`.

```bash
WHISPER_MODEL=medium verify/venv/bin/python verify/verify_audio_language.py \
  --input reports/missing-italian-audio.csv \
  --output reports/verified-language-results.csv --retry-errors --limit 5
```

Custom paths:

```bash
./verify/verify-audio-language.sh /path/to/input.csv /path/to/output.csv
```

Worker exit codes:

| Code  | Meaning |
|-------|---------|
| `0`   | finished (including "nothing new to verify") |
| `1`   | configuration, input, output path or disk-space problem, or the model could not be loaded |
| `2`   | usage error: an unknown flag or a bad value (argparse) |
| `3`   | every file this run tried to verify errored |
| `130` | interrupted (Ctrl-C); the CSV written so far stays valid |

Errors before publication leave the previous CSV untouched. During processing,
a controlled abort preserves completed results and pending previous verdicts,
as described above.

The launcher returns `1` for its own usage errors and for a failed pre-flight,
and otherwise passes the worker's codes through unchanged. `2` always comes from
the worker: calling it by hand with a bad flag, or giving the launcher a
non-numeric `LIMIT`, which is forwarded as `--limit` and rejected by argparse.

### Phase 2 report (HTML)

The CSV is the canonical output. `verify/report.py` turns it into a single
self-contained HTML file (inline CSS + JS, no external resources, works
offline) that is easier to browse: filter chips per verdict, free-text
search on title/path, sortable columns, a summary bar, and "copy path" /
"Copy filtered paths" buttons to build a redownload list. Standard library
only, no extra dependencies.

To stay light on big libraries the table stops at 2000 rows and offers a
*Show all N rows* button to render the rest.

Filters and sorting also work with the keyboard. Copy includes all filtered
results, including those beyond the display cap, with duplicate paths removed.
If the browser denies clipboard access (for example over LAN HTTP), selected
text is shown for manual copying. HTML replacement is atomic; malformed CSV
and output paths aliasing the input or listed media are refused.

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
stopped cleanly), `1` for missing/invalid CSV, a refused/unwritable output or
a server error. A bind error can occur after the HTML has been written.
Invalid arguments (including a port outside
`0..65535`) exit `2` before writing the HTML.

## Configuration

### The `.env` file

The three shell entry points read it: orchestrator, scanner and launcher.
The Python worker uses environment variables and flags when invoked directly;
`report.py` uses its own arguments and does not load `.env`.

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
beats what `.env` says, and `--refresh` beats both. *Reconfigure* edits the
active file, including `ALA_DOTENV_FILE` or the `scan/.env` fallback. API calls
use `curl -q`, ignoring `.curlrc` so implicit extra URLs or redirects cannot
receive the key. Standard curl environment variables for proxies and
certificates remain available.

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
ignores the Sonarr cache for that run. `RESCAN_TIMEOUT` accepts `0` through
`999999999` seconds and `RESCAN_POLL_INTERVAL` accepts `1` through `999999999`.
Status-polling HTTP requests and sleeps respect the remaining timeout budget;
the initial POST that queues the rescan uses `ARR_TIMEOUT` instead.

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
| `LIMIT`             | `0` (unlimited) | Only (re)verify the first N planned rows; nonnegative integer |
| `RETRY_ERRORS`      | `false`   | `true` to also reprocess retryable rows (`FILE_NOT_FOUND`, `EXTRACTION_FAILED`, `DETECTION_FAILED`, `LOW_CONFIDENCE`) |
| `NO_RESUME`         | `false`   | `true` to ignore an existing output CSV and start fresh |

### Environment-only variables

These are not on the `.env` allow-list (putting them there produces a warning):
pass them in the command's environment.

| Variable          | Default     | Meaning |
|-------------------|-------------|---------|
| `ALA_DOTENV_FILE` | —           | Read this `.env` instead of searching the repository |
| `ARR_PLAIN_MENU`  | —           | Set to anything, forces the plain numbered menu even when `whiptail` is installed |
| `ARR_TIMEOUT`     | `120`       | Ordinary API request timeout; rescan polling and pre-flight probes apply their own limits |
| `ARR_PROBE_TIMEOUT` | `3`       | Timeout for each orchestrator pre-flight probe |
| `ARR_RETRY_DELAY` | `2`         | Seconds between two attempts of a failed request |
| `ARR_ASSUME_TTY`  | —           | `1` runs the phase 1 wizard without a terminal |
| `ARR_LOCALHOST`   | `localhost` | The host the wizard's `/ping` probe tries |

The orchestrator, scanner, launcher, Python worker and HTML generator accept
`-h` / `--help`. The launcher takes positional input and output arguments;
the worker uses `--input` and `--output`. The options `--retry-errors`,
`--limit` and `--no-resume` belong to the worker: use `RETRY_ERRORS`, `LIMIT`
and `NO_RESUME` respectively with the launcher.

## Output verdicts (phase 2)

| Verdict                 | Meaning | Suggested action |
|-------------------------|---------|------------------|
| `MISTAGGED_IS_ITALIAN`  | The sample is detected as Italian with sufficient confidence | Check the track, then correct tags / mediaInfo and rescan |
| `CONFIRMED_NOT_ITALIAN` | The sample is detected as non-Italian with sufficient confidence | Check the other tracks before deciding to remux or download |
| `LOW_CONFIDENCE`        | Language detected below `MIN_CONFIDENCE`; inconclusive result | Change the model or sample position and rerun with `RETRY_ERRORS=true` |
| `FILE_NOT_FOUND`        | Path from the phase 1 CSV is not visible on this machine | Mount the library, or run phase 2 where the files live |
| `EXTRACTION_FAILED`     | `ffmpeg` could not produce a sample | Inspect the file manually |
| `DETECTION_FAILED`      | `faster-whisper` raised on the sample, or could not name a language at all | Retry with `RETRY_ERRORS=true`, optionally using a larger model |

`DetectedLanguage` is an ISO code (`it`, `en`, `de`, …); `Confidence` is the
model's language-detection probability (`0.00`–`1.00`).

## Troubleshooting

| Symptom | Check and action |
|---|---|
| An app is unconfigured or unreachable | Check its URL, key and reachability from the toolkit host; set `SKIP_RADARR=true` or `SKIP_SONARR=true` only for the app you intend to exclude |
| The scan exits `2` | Read the request named in the error, fix connectivity or the API response, and rerun; the previous CSV is not a newly completed scan |
| Every result is `FILE_NOT_FOUND` | Compare CSV paths with local mounts: Docker/NAS paths are not mapped automatically |
| The phase 2 environment is not ready | Run `./verify/verify-audio-language.sh --check`; install `verify/requirements.txt` into the indicated interpreter or choose a suitable `PYTHON_BIN` |
| Insufficient temporary space | Free space or choose `TEMP_DIR=/path/with/space`; the worker uses a private subdirectory and checks `MIN_FREE_SPACE_MB` |
| Low-confidence results persist | Changing the model alone does not invalidate resume: also use `RETRY_ERRORS=true`; `NO_RESUME=true` regenerates all results |
| Corrected tags but unchanged phase 1 results | Use `--refresh` to fetch Sonarr again; `FORCE_RESCAN=true` also asks the APIs to rescan the files first |
| Clipboard copying is unavailable | Use the selected text shown by the report and copy manually with Ctrl+C / Command+C |

## Notes and limitations

- What is listened to is the audio stream the container marks as **default**
  (else the first one), when `ffprobe` returns usable data. If the probe fails,
  stream selection is left to ffmpeg.
  **Only the sampled window decides**: a file whose
  sampled minutes are music, or whose tracks differ from the default one, is
  judged on what that window contains. That is precisely why a detection below
  `MIN_CONFIDENCE` is reported as `LOW_CONFIDENCE` rather than as an answer.
- A phase 1 candidate with an English default track and a secondary Italian
  track can be classified as `CONFIRMED_NOT_ITALIAN`: sampling does not
  inventory every track. A file already tagged Italian is excluded from
  phase 1, even if that tag is wrong.
- Detection runs through faster-whisper's `detect_language` API with the VAD
  filter on and up to **two** windows: the second is tried when the first comes
  back under the detection threshold (`0.5`), which is what a sample opening on music
  or on a silent title card needs. On a `faster-whisper` too old for that
  method it falls back to `transcribe()`. Films that open with a long
  non-dialogue stretch, or that mix languages, can still fool it — adjust
  `SAMPLE_SECONDS` / `SAMPLE_OFFSET_PCT`, or bump `WHISPER_MODEL`.
- `MIN_CONFIDENCE` filters a model score; it does not certify accuracy.
  Repository tests check behavior and integrations, not language recognition
  accuracy on a real library.
- CSV and cache are replaced separately. A complete scan can publish its CSV
  and report a cache-write error: the CSV remains valid, while an absent or
  older cache may require another fetch.

## Development

You need `bats-core` (the `bats-support` / `bats-assert` libraries are already
vendored in `tests/bats/lib`), `shellcheck` and
[`uv`](https://github.com/astral-sh/uv) — `ruff` and `pytest` run through
`uvx`, without installing Python packages into the project. Report tests also
need Node.js ≥ 22 and npm; `npm ci` installs test-only dependencies under
`tests/report-ui/node_modules`, ignored by Git.

```bash
./scripts/test.sh all      # lint, pytest, bats, report and real audio contract
./scripts/test.sh lint     # shellcheck -S warning over the scripts + ruff check .
./scripts/test.sh py       # pytest on 3.12 and on the 3.9 floor
./scripts/test.sh bats     # the bats suite, forced onto /bin/bash
./scripts/test.sh ui       # report interactions in jsdom, without a browser
./scripts/test.sh contract # real faster-whisper decoder/API, without model weights
```

CI (`.github/workflows/ci.yml`) covers the same five stages: the *lint* job
on `ubuntu-latest` calls `scripts/test.sh lint`; the *bats* job (`ubuntu-latest`
and `macos-latest`) and the *pytest* job (`ubuntu-latest` × `macos-latest`
matrix for Python `3.9`, `3.12` and `3.13`) run their commands inline because
they need the OS and interpreter matrix; the local script covers `3.9` and
`3.12`, CI adds `3.13`. The Linux `report-ui` job runs `scripts/test.sh ui`,
executing the generated JavaScript to check filtering, sorting, copying,
clipboard failures and the row cap. Node.js is not needed to use the toolkit
or view the report. The Linux `whisper-contract` job (Python 3.9 and 3.12)
installs the dependency pinned in `verify/requirements.txt`, testing the real
PyAV decoder, 16 kHz float32 waveform and detection API without downloading
weights. Only VAD decisions and neural outputs are stubbed; this does not
measure language-recognition accuracy.

**The bash 3.2 gate.** Locally and in CI the bats suite runs with
`PATH="/bin:/usr/bin:$PATH"` and `BASH_UNDER_TEST=/bin/bash`, so on macOS the
scripts are executed by the system bash 3.2 and not by Homebrew's 5.x; one test
asserts it really is on bash 3 when running on macOS, and another greps the
sources for constructs that need bash 4 (`mapfile`, `declare -A`, `${var,,}`, …)
and fails if it finds any.

**How the fakes work.** Tests do not contact external services or real
models; fake servers use loopback networking only. Initial uv/npm setup may
download the test tools. The bats suite uses real `curl` and `jq` against a
fake Radarr/Sonarr HTTP server answering from `tests/bats/fixtures`. Shims for
`ffmpeg`, `ffprobe`, `python3`, `df`, `uname`, `whiptail`, `apt` and `recorder`
are controlled through environment variables. In the standard Python suite, a stub
`faster_whisper` package on `PYTHONPATH` reads the marker the `ffmpeg` shim
wrote into the "sample" and answers from a JSON script, so a test declares what
language a given file "is" without decoding a byte of audio.

Architecture decisions live in [`docs/adr/`](docs/adr/); user-visible changes in
[`CHANGELOG.md`](CHANGELOG.md). The [initial audit](docs/audit/2026-09-05-deep-audit.md)
and [follow-up review](docs/audit/2026-09-05-pr-follow-up.md) document reproduced
defects, their fixes and the limits of verification.

## Adapting to another language

- **Phase 1:** change `ITALIAN_REGEX` in `scan/find-missing-italian-audio.sh`.
- **Phase 2:** change `is_italian()` in `verify/verify_audio_language.py`.
- Update verdict constants, report labels and filters, fixtures, tests and
  documentation together; renaming a verdict alone does not change the language.

There is no runtime option for the target language: this requires a code
change. Use new outputs or `NO_RESUME=true` to avoid reusing verdicts computed
with the previous criterion.

## License

[MIT](LICENSE) - 2026 Giovanni Solone
