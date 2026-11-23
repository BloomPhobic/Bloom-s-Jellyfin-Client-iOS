import SwiftUI

/// The server's scheduled tasks (library scan, clean-ups, ...): when they last ran, run or stop them,
/// and watch a running one's progress.
struct AdminTasksView: View {
    @Environment(SessionStore.self) private var store
    @State private var tasks: [TaskRow] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var message: String?

    private struct TaskRow: Identifiable {
        let id: String
        let name: String
        let category: String
        let details: String
        let isRunning: Bool
        let isStopping: Bool
        let progress: Double?
        let lastStatus: String?
        let lastEnd: Date?
    }

    private var categories: [String] {
        var order: [String] = []
        for task in tasks where !order.contains(task.category) {
            order.append(task.category)
        }
        return order
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 14)).foregroundStyle(Theme.text2)
                } else if loaded && tasks.isEmpty {
                    Text("No tasks.").font(.system(size: 14)).foregroundStyle(Theme.text2)
                }
                ForEach(categories, id: \.self) { category in
                    AdminGroupTitle(text: category)
                    ForEach(tasks.filter { $0.category == category }) { task in
                        row(task)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .themedBackground()
        .tabBarClearance()
        .navigationTitle("Scheduled tasks")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            // Poll while the page is open: quickly while something runs, slowly otherwise.
            while !Task.isCancelled {
                await load()
                let busy = tasks.contains { $0.isRunning }
                try? await Task.sleep(for: .seconds(busy ? 2 : 10))
            }
        }
        .toast($message)
    }

    private func row(_ task: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if !task.details.isEmpty {
                        Text(task.details)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    Task { await toggle(task) }
                } label: {
                    Image(systemName: task.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(task.isRunning ? Color.red : Theme.accent)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.raised2))
                }
                .buttonStyle(PressableStyle())
                .disabled(task.isStopping)
                .accessibilityLabel(task.isRunning ? "Stop \(task.name)" : "Run \(task.name)")
            }
            if task.isRunning {
                let percent = task.progress ?? 0
                ProgressBar(fraction: percent / 100, height: 4)
                Text(task.isStopping ? "Stopping…" : "Running · \(Int(percent))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            } else {
                Text(lastRun(task))
                    .font(.system(size: 12))
                    .foregroundStyle(task.lastStatus == "Failed" ? Color.red : Theme.text3)
            }
        }
        .adminCard()
    }

    private func lastRun(_ task: TaskRow) -> String {
        guard let status = task.lastStatus else { return "Never run" }
        return "Last run \(AdminDate.ago(task.lastEnd)) · \(status)"
    }

    private func load() async {
        do {
            guard let rows = try await store.adminJSON("ScheduledTasks") as? [[String: Any]] else { return }
            var found: [TaskRow] = []
            for row in rows {
                guard let id = row["Id"] as? String else { continue }
                let hidden = row["IsHidden"] as? Bool ?? false
                if hidden { continue }
                let state = row["State"] as? String ?? "Idle"
                let last = row["LastExecutionResult"] as? [String: Any]
                found.append(TaskRow(
                    id: id,
                    name: row["Name"] as? String ?? "Task",
                    category: row["Category"] as? String ?? "Other",
                    details: row["Description"] as? String ?? "",
                    isRunning: state == "Running" || state == "Cancelling",
                    isStopping: state == "Cancelling",
                    progress: (row["CurrentProgressPercentage"] as? NSNumber)?.doubleValue,
                    lastStatus: last?["Status"] as? String,
                    lastEnd: AdminDate.parse(last?["EndTimeUtc"] as? String)
                ))
            }
            tasks = found
            errorMessage = nil
            loaded = true
        } catch {
            guard !isCancelled(error) else { return }
            errorMessage = "Couldn't load the tasks: \(error.localizedDescription)"
            loaded = true
        }
    }

    private func toggle(_ task: TaskRow) async {
        do {
            _ = try await store.adminCall("ScheduledTasks/Running/\(task.id)", method: task.isRunning ? "DELETE" : "POST")
            message = task.isRunning ? "Stopping “\(task.name)”" : "Started “\(task.name)”"
            await load()
        } catch {
            message = "Couldn't do that: \(error.localizedDescription)"
        }
    }
}
