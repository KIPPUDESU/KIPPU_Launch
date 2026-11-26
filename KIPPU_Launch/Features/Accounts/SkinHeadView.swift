import KIPPULaunchCore
import SwiftUI

struct SkinHeadView: View {
    let head: SkinHead?
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            if let head {
                Image(decorative: head.head, scale: 1)
                    .interpolation(.none)
                    .resizable()
                if let hat = head.hat {
                    Image(decorative: hat, scale: 1)
                        .interpolation(.none)
                        .resizable()
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16))
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
            }
    }
}
