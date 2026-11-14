import FaceFinderKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete: PersonRecord?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    Label("Thư viện ảnh", systemImage: "photo.stack")
                        .badge(model.isIndexing ? Text(Image(systemName: "arrow.triangle.2.circlepath")) : nil)
                        .tag(SidebarItem.library)
                }
                Section("Người") {
                    ForEach(model.people) { person in
                        PersonRow(person: person)
                            .tag(SidebarItem.person(person.id))
                            .contextMenu {
                                Button("Xoá người…", role: .destructive) { confirmDelete = person }
                            }
                    }
                    if model.people.isEmpty {
                        Text("Chưa có ai").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.showNewPerson = true
                } label: {
                    Label("Thêm người…", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .padding(12)
            }
        } detail: {
            switch model.selection {
            case .person(let id):
                if let person = model.person(id) {
                    PersonView(person: person).id(id)
                } else {
                    LibraryView()
                }
            default:
                LibraryView()
            }
        }
        .sheet(isPresented: $model.showNewPerson) {
            NewPersonSheet()
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
        .confirmationDialog("Xoá \(confirmDelete?.name ?? "")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Xoá", role: .destructive) {
                if let p = confirmDelete { model.delete(p) }
            }
        } message: {
            Text("Xoá người này và khuôn mặt mẫu khỏi app. Thư mục kết quả đã ghi ra vẫn được giữ nguyên.")
        }
    }
}

struct PersonRow: View {
    let person: PersonRecord

    var body: some View {
        HStack(spacing: 8) {
            FaceThumb(data: person.references.first?.thumbnail, size: 26)
            Text(person.name).lineLimit(1)
        }
    }
}

/// Ảnh khuôn mặt mẫu (JPEG nhỏ đã lưu).
struct FaceThumb: View {
    let data: Data?
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.square").resizable().scaledToFit().foregroundStyle(.secondary).padding(size / 6)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 6))
    }
}
