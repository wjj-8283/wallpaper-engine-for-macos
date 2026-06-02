import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            ProgramSettingsSection()
            PowerSettingsSection()
            DisplaySettingsSection()
            AboutSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
