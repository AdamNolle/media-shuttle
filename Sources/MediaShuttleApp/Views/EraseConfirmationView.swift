import SwiftUI

struct EraseConfirmationView: View {
    @Bindable var model: AppModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var phrase = ""
    @State private var acknowledged = false
    @FocusState private var phraseIsFocused: Bool

    private var isConfirmed: Bool {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines) == "ERASE EVERYTHING" && acknowledged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        LinearGradient(
                            colors: [.red, .red.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                    .shadow(color: Color.red.opacity(0.24), radius: 10, y: 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Erase everything on this card?")
                        .font(.title2.weight(.bold))
                    Text(model.currentCard?.volumeLabel ?? "Camera media")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Label {
                Text(
                    "Every media file will be re-verified against its destination copy before deletion begins. " +
                    "Camera databases, sidecars, and all other user content will also be removed."
                )
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            }
            .font(.system(size: 13))
            .padding(14)
            .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                Text("Type ERASE EVERYTHING to continue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("ERASE EVERYTHING", text: $phrase, prompt: Text("ERASE EVERYTHING"))
                    .textFieldStyle(.roundedBorder)
                    .focused($phraseIsFocused)
            }

            Toggle(isOn: $acknowledged) {
                Text(
                    "I understand this permanently removes all files and folders from " +
                    (model.currentCard?.rootURL.path ?? "the card") + "."
                )
            }
            .toggleStyle(.checkbox)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Erase Card Contents", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isConfirmed || !model.canWipe)
            }
        }
        .padding(26)
        .frame(width: 560)
        .onAppear { phraseIsFocused = true }
    }
}
