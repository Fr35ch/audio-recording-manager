import Foundation

enum AppCopy {
    enum Menu {
        static let logViewer = "Loggvisning"
        static let designSystem = "Design system"
        static let settingsWithEllipsis = "Innstillinger …"
    }

    enum Common {
        static let cancel = "Avbryt"
        static let cancelEnglish = "Cancel"
        static let close = "Lukk"
        static let retry = "Prøv igjen"
        static let save = "Lagre"
        static let saveAndClose = "Lagre og lukk"
        static let delete = "Slett"
        static let open = "Åpne"
        static let transcribe = "Transkriber"
        static let download = "Last ned"
        static let settings = "Innstillinger"
        static let continueAction = "Fortsett"
        static let continueWithAnonymization = "Fortsett med anonymisering"
        static let discard = "Forkast"
        static let confirm = "Bekreft"
        static let confirmRequirements = "Bekreft krav"
        static let confirmAndUpload = "Bekreft og last opp"
        static let approveAndSign = "Godkjenn og signer"
        static let ok = "OK"
        static let create = "Create"
        static let keep = "Behold"
        static let edit = "Rediger"
        static let showAll = "Vis alle"
        static let refresh = "Oppdater"
        static let unlock = "Lås opp"
        static let add = "Legg til"
        static let withdraw = "Trekk tilbake"
        static let renameFile = "Endre filnavn"
        static let uploadToTeams = "Last opp til Teams"
    }

    enum Labels {
        static let copy = "Kopier"
        static let export = "Eksporter"
        static let newIteration = "Ny iterasjon"
        static let rawModelResponse = "Rå modellrespons"
        static let deleteAnalysis = "Slett analyse"
        static let researchContextOptional = "Forskningskontekst (valgfritt)"
        static let selectTranscripts = "Velg transkripsjon(er)"
        static let selectAnalysisTemplate = "Velg analyse-mal"
        static let runAnalysis = "Kjør analyse"
        static let deleteRecording = "Slett opptak"
        static let modelReadyForUse = "Modellen er klar til bruk"
        static let readyForUse = "Klar til bruk"
        static let notDownloaded = "Ikke lastet ned"
        static let openInTranscriptEditor = "Åpne i transkripsjonseditoren"
        static let transcribeAgain = "Transkriber på nytt"
        static let transcribeWithNBWhisper = "Transkriber med NB-Whisper"
        static let setupFailed = "Oppsett feilet"
        static let runAgain = "Kjør på nytt"
        static let identifySpeakers = "Identifiser talere"
        static let noTranscribeMissing = "no-transcribe er ikke installert. Åpne innstillinger for å installere."
        static let resetToRecommendedExceptions = "Tilbakestill til anbefalte unntak"
        static let iConfirm = "Jeg bekrefter"
        static let destination = "Destinasjon"
        static let teamsFilename = "Filnavn på Teams"
        static let confirmation = "Bekreftelse"

        static let transcriptionAuto = "Transkriber lydfil automatisk"
        static let transcriptionPreparing = "Forbereder..."
        static let transcriptionModelFirstRunHint = "NB-Whisper-modellen lastes ved første kjøring – dette kan ta et minutt."
        static let transcriptionCompleted = "Transkripsjon fullført"
        static let transcriptionFailed = "Feil ved transkripsjon"
        static let unknownError = "Ukjent feil"
        static let diarization = "Taleutskilling"
        static let diarizationDescription = "Identifiser hvem som snakker i opptaket"
        static let runDiarization = "Kjør taleutskilling"
        static let researchContextHint = "Én eller to setninger om hva studien handler om. Gir LLM-en bedre forutsetninger for å tolke materialet."
        static let noTranscriptsYet = "Ingen transkripsjoner ennå"
        static let runWhisperBeforeAnalysis = "Kjør NB-Whisper på et lydopptak før du starter en analyse."
        static let noTemplatesAvailable = "Ingen maler tilgjengelig for valgt kombinasjon."
        static let noneSelected = "Ingen valgt"
        static let singleSelected = "1 valgt → Enkeltanalyse"

        static func groupSelected(_ count: Int) -> String {
            "\(count) valgt → Gruppeanalyse"
        }

        static func model(_ displayName: String) -> String {
            "Modell: \(displayName)"
        }

        static func speakerCount(_ count: Int) -> String {
            "\(count) taler\(count == 1 ? "" : "e")"
        }

        static func segmentCount(_ count: Int) -> String {
            "\(count) segmenter"
        }
    }

    enum MobileTransfer {
        static let disconnectedTitle = "iPhone frakoblet"

        static func disconnectedDescription(_ deviceName: String) -> String {
            "\(deviceName) ble koblet fra. Koble til iPhone igjen via USB eller Wi-Fi for å fortsette."
        }

        static let importAction = "Importer"
        static let alreadyImported = "Importert"

        static let waitingTitle = "Venter på iPhone"
        static let waitingDescription = "Koble iPhonen til med USB-kabel og åpne Clio Recorder. Biblioteket åpnes automatisk."

        static let openAppTitle = "Åpne Clio Recorder"
        static func openAppDescription(_ deviceName: String) -> String {
            "\(deviceName) er tilkoblet. Åpne Clio Recorder-appen på iPhone for å gjøre opptakene tilgjengelige."
        }

        static let airDropImportedTitle = "Opptak importert via AirDrop"

        static func airDropImportedBody(_ filename: String) -> String {
            "\(filename) er lagt til i biblioteket."
        }
    }
}
