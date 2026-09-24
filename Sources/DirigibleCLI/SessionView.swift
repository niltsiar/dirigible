import DirigibleCore
import Foundation

/// The text summary of `info`: one line for the session, then one line for each object.
func summary(of session: Session, name: String) -> String {
    "\(name): \(session.sampleRate) Hz\n"
}
