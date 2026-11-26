import KIPPULaunchCore
import SwiftUI

struct WorldPicker: View {
    let worlds: [SavedWorld]
    @Binding var selection: SavedWorld?

    var body: some View {
        Picker("世界", selection: $selection) {
            ForEach(worlds) { world in
                Text(world.name == world.folder ? world.name : "\(world.name)（\(world.folder)）")
                    .tag(Optional(world))
            }
        }
    }
}
