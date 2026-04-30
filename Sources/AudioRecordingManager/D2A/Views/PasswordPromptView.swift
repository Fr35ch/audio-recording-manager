// PasswordPromptView.swift
// AudioRecordingManager / D2A
//
// Modal sheet shown when the researcher imports a (presumed-encrypted)
// D2A file. Returns the entered password via `onSubmit`. The view does
// not validate the password itself — the VM service is the only thing
// that knows whether it's correct.

import SwiftUI

struct PasswordPromptView: View {
    let fileName: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var password: String = ""
    @State private var showPassword: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Passord kreves")
                    .font(.headline)
                Text("Filen \"\(fileName)\" er kryptert.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: AppSpacing.sm) {
                Group {
                    if showPassword {
                        TextField("Passord", text: $password)
                    } else {
                        SecureField("Passord", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showPassword ? "Skjul passord" : "Vis passord")
            }

            HStack {
                Button("Avbryt", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Dekrypter") {
                    onSubmit(password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.count < 4)
            }
        }
        .padding(AppSpacing.xl)
        .frame(width: 420)
    }
}
