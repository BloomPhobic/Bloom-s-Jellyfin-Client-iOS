import SwiftUI

/// Approves a Quick Connect sign-in on another device (a TV, a browser): type the 6-digit code it
/// shows, and that device is signed in as the account used here.
struct QuickConnectAuthorizeView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var code = ""
    @State private var isWorking = false
    @State private var result: (text: String, isError: Bool)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Theme.accent.opacity(0.15)))
                .padding(.top, 26)
            Text("Authorize Quick Connect")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("On the other device, choose Quick Connect and type the 6-digit code it shows here. It will be signed in as \(store.session?.userName ?? "this account").")
                .font(.system(size: 14))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised))
                .onChange(of: code) {
                    let digits = String(code.filter(\.isNumber).prefix(6))
                    if digits != code { code = digits }
                    result = nil
                }

            if let result {
                Text(result.text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(result.isError ? Color.red : Color.green)
            }

            Button {
                Task { await authorize() }
            } label: {
                HStack(spacing: 8) {
                    Text("Authorize")
                    if isWorking {
                        ProgressView().tint(Theme.onAccent)
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: 50))
            .opacity(code.count == 6 && !isWorking ? 1 : 0.4)
            .disabled(code.count != 6 || isWorking)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.surface)
        .onAppear { focused = true }
    }

    private func authorize() async {
        isWorking = true
        defer { isWorking = false }
        do {
            if try await store.authorizeQuickConnect(code: code) {
                result = ("Approved. The other device is signing in.", false)
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            } else {
                result = ("That code wasn't accepted. Check it and try again.", true)
            }
        } catch {
            result = ("That code wasn't accepted, or Quick Connect is off on the server.", true)
        }
    }
}
