import SwiftUI

struct ConnectionView: View {
    @State private var model = ConnectionCheckModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.addresses, id: \.self) { address in
                        AddressRow(
                            address: address,
                            result: model.results[address],
                            isChosen: model.chosenAddress == address
                        )
                    }
                    .onDelete { model.remove(at: $0) }
                    .onMove { model.move(from: $0, to: $1) }

                    HStack {
                        TextField("http://192.168.1.10:8096", text: $model.newAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit { model.addAddress() }
                        Button("Add") { model.addAddress() }
                            .disabled(model.newAddress.isEmpty)
                    }
                } header: {
                    Text("Server addresses")
                } footer: {
                    if let inputError = model.inputError {
                        Text(inputError).foregroundStyle(.red)
                    } else {
                        Text("All addresses are tried at the same time. The first one in this list that answers is used. Tap Edit to reorder.")
                    }
                }

                Section {
                    Button {
                        Task { await model.check() }
                    } label: {
                        HStack {
                            Text("Check reachability")
                            if model.isChecking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isChecking || model.addresses.isEmpty)
                }

                Section("Self-tests") {
                    Button("Run Keychain test again") {
                        KeychainCheck.run()
                    }
                }
            }
            .navigationTitle("Connection")
            .toolbar { EditButton() }
        }
    }
}

private struct AddressRow: View {
    let address: String
    let result: ProbeResult?
    let isChosen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(address)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isChosen {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let result {
                switch result.outcome {
                case .reachable(let name, let version, let ms):
                    Text("\(name) · \(version) · \(ms) ms")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
