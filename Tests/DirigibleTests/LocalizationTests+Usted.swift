import Foundation
import Testing

@testable import DirigibleApp

/// The Spanish UI addresses the user as tú (decision 0010). No `es` value uses `usted`, or a usted
/// imperative of `ustedImperatives`.
extension LocalizationTests {
    @Test func noSpanishTextUsesUsted() throws {
        var read: [String] = []
        var found: [String] = []
        for file in ["Localizable", "InfoPlist"] {
            let table = try stringsTable("es", file: file)
            if !table.isEmpty { read.append(file) }
            found += ustedFindings(table)
        }
        #expect(read == ["Localizable", "InfoPlist"])
        #expect(found.isEmpty, "\(found)")
    }

    @Test func ustedCheckerFindsUstedAndKeepsTuSubjunctivesAndNouns() {
        let examples: [(String, [String])] = [
            ("Compruebe el disco y vuelva a intentarlo.", ["compruebe", "vuelva"]),
            ("Vuelva a poner el archivo en esa carpeta e inténtelo de nuevo.", ["vuelva", "inténtelo"]),
            (
                "En Marcadores, elija la imagen de nuevo o quítela. Después exporte de nuevo.",
                ["elija", "quítela", "exporte"]
            ),
            ("Para que el audio se guarde, compruebe el disco.", ["compruebe"]),
            ("Si usted quiere, pulse Grabar.", ["usted", "pulse"]),
            ("Asegúrate de que hay espacio y vuelva a intentarlo.", ["vuelva"]),
            ("Revise el disco, descárguelo y restaure el archivo.", ["revise", "descárguelo", "restaure"]),
            ("Revisa el disco, descárgalo y restaura el archivo.", []),
            ("Comprueba el disco y vuelve a intentarlo.", []),
            ("Vuelve a poner el archivo en esa carpeta e inténtalo de nuevo.", []),
            ("En Marcadores, elige la imagen de nuevo o quítala. Después exporta de nuevo.", []),
            ("Muévelos y exporta de nuevo. Usa un archivo WAV.", []),
            ("Hay una toma en curso o terminando. Espera a que termine.", []),
            ("Permite que Dirigible termine la toma.", []),
            ("Espera hasta que se actualice la lista, y vuelve a intentarlo.", []),
            ("No volver a preguntar hasta que cierre esta ventana", []),
            ("Ajuste", []),
            ("Informe guardado. El próximo arranque restaura la toma.", []),
            ("La app vuelve a comprobarlo. Sus clips suenan como silencio.", []),
            ("Las pistas usan el mismo canal. Una escritura falló.", []),
        ]
        for (value, words) in examples { #expect(ustedWords(value) == words, "\(value)") }
        let infoPlist = ["NSMicrophoneUsageDescription": "Use el micrófono para grabar."]
        #expect(ustedFindings(infoPlist) == ["NSMicrophoneUsageDescription: use"])
    }
}

/// The usted imperatives that the `es` table could use: the usted form of each verb that the table
/// has as a tú imperative. A form that is also a common noun (ajuste, informe, importe, cierre,
/// arrastre) is out, because a sentence that starts with the noun would be a false hit.
private let ustedImperatives: Set<String> = [
    "abra", "actualice", "active", "añada", "borre", "bórrelo", "busque", "cambie", "ciérrela", "compruebe",
    "conecte", "copie", "defina", "desactive", "desactívelo", "descargue", "descárguelo", "desplace", "divida",
    "divídalo", "edite", "elija", "elimínelo", "escriba", "espere", "exporte", "haga", "inténtelo", "instale",
    "libere", "mueva", "muévala", "muévalos", "péguelo", "permita", "pulse", "quite", "quítela", "reinicie",
    "repita", "restaure", "revise", "salga", "seleccione", "termine", "use", "vuelva",
]

/// The usted words of a value, in order: `usted` and `ustedes`, and each listed imperative with no
/// `que` before it in its clause (a clause ends at `.:;!?,` or a new line). After `que` the form is
/// a subjunctive ("Espera a que termine"); `y`, `o`, `e`, and `u` end that effect until the next `que`.
private func ustedWords(_ value: String) -> [String] {
    var found: [String] = []
    for clause in value.split(whereSeparator: { ".:;!?,\n".contains($0) }) {
        var afterQue = false
        for word in clause.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) {
            switch word {
            case "usted", "ustedes": found.append(word)
            case "que": afterQue = true
            case "y", "o", "e", "u": afterQue = false
            default: if !afterQue && ustedImperatives.contains(word) { found.append(word) }
            }
        }
    }
    return found
}

/// `key: word` for each usted word of each value, in the order of the keys.
private func ustedFindings(_ table: [String: String]) -> [String] {
    table.sorted { $0.key < $1.key }.flatMap { key, value in ustedWords(value).map { "\(key): \($0)" } }
}
