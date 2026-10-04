import SwiftUI
import TripCore

/// First step: where the group server is. Usually done by an invitation link; typed once by whoever sets the
/// group up (the key is the public one: it protects nothing by itself, the server's rules do).
struct GroupServerForm: View {
    @EnvironmentObject private var group: GroupSession
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var key = ""

    var body: some View {
        List {
            if group.config == nil {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3.fill").font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(Theme.rideGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        Text("Roule en groupe").font(.title2.bold())
                        Text("Parle avec tes amis, vois-les sur la carte, écris-leur d'un geste et partage tes trips. Seulement quand tu le veux : la navigation n'en dépend jamais.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                PasteInviteButton()
            } header: {
                Text("Un ami t'a invité ?")
            } footer: {
                Text("Ouvre son lien d'invitation, ou colle ici le message reçu : le serveur et le code se règlent tout seuls.")
            }
            Section {
                TextField("https://xxxx.supabase.co", text: $url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Clé publique (anon)", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Enregistrer") {
                    if group.configure(url: url, anonKey: key), group.config != nil { dismiss() }
                }
                .disabled(url.isEmpty || key.isEmpty)
            } header: {
                Text("Je crée le groupe")
            } footer: {
                Text("Adresse et clé publique de ton projet (voir backend/README.md). Tu pourras ensuite inviter tes amis par un lien.")
            }
            if let error = group.lastError { Section { Text(error).foregroundStyle(Theme.camera) } }
        }
        .motoList()
        .tint(Theme.accent)
        .keyboardDoneButton()
        .navigationTitle("Serveur")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            url = group.config?.url ?? ""
            key = group.config?.anonKey ?? ""
        }
    }
}

/// Create an account (pseudo, e-mail, password) or sign in.
struct GroupSignInView: View {
    @EnvironmentObject private var group: GroupSession
    enum Mode { case signUp, signIn }
    @State private var mode = Mode.signUp
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        List {
            if let code = group.pendingInvite {
                Section {
                    GroupRow(title: "Invitation reçue", icon: "envelope.open.fill", tint: Theme.ok,
                             subtitle: "Crée ton compte : tu rejoindras le groupe tout de suite (code \(code))")
                }
            }
            Section {
                Picker("", selection: $mode) {
                    Text("Créer un compte").tag(Mode.signUp)
                    Text("Me connecter").tag(Mode.signIn)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section {
                if mode == .signUp {
                    TextField("Pseudo (vu par ton groupe)", text: $name).autocorrectionDisabled()
                }
                TextField("E-mail", text: $email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(mode == .signUp ? "Mot de passe (8 caractères minimum)" : "Mot de passe", text: $password)
                Button {
                    Task {
                        if mode == .signUp { _ = await group.signUp(email: email, password: password, name: name) }
                        else { _ = await group.signIn(email: email, password: password) }
                    }
                } label: {
                    HStack {
                        Text(mode == .signUp ? "Créer mon compte" : "Me connecter").font(.headline)
                        if group.busy { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(group.busy || email.isEmpty || password.isEmpty || (mode == .signUp && name.isEmpty))
            } footer: {
                Text("Ton e-mail sert uniquement à te connecter. Ton pseudo est vu par les membres de tes groupes.")
            }
            if let notice = group.notice { Section { Label(notice, systemImage: "envelope.fill").foregroundStyle(Theme.ok) } }
            if let error = group.lastError { Section { Text(error).foregroundStyle(Theme.camera) } }
            Section {
                NavigationLink { GroupServerForm() } label: {
                    GroupRow(title: "Serveur du groupe", icon: "server.rack", tint: .gray,
                             value: group.config.flatMap { URL(string: $0.url)?.host })
                }
            }
        }
        .motoList()
        .tint(Theme.accent)
        .keyboardDoneButton()
    }
}

/// Who I am in the group app, sign out, delete the account.
struct GroupAccountView: View {
    @EnvironmentObject private var group: GroupSession
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                GroupRow(title: "Pseudo", icon: "person.fill", tint: Theme.accent, value: group.myName)
                GroupRow(title: "E-mail", icon: "envelope.fill", tint: Theme.info, value: group.email)
                NavigationLink { GroupServerForm() } label: {
                    GroupRow(title: "Serveur du groupe", icon: "server.rack", tint: .gray,
                             value: group.config.flatMap { URL(string: $0.url)?.host })
                }
            }
            Section {
                Button { Task { await group.signOut() } } label: {
                    Label("Me déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Supprimer mon compte", systemImage: "trash")
                }
            } footer: {
                Text("Supprimer le compte efface ton profil, ta position, tes messages et tes trips partagés sur le serveur. Tes trips restent sur ton iPhone.")
            }
            if let error = group.lastError { Section { Text(error).foregroundStyle(Theme.camera) } }
        }
        .motoList()
        .tint(Theme.accent)
        .navigationTitle("Mon compte")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Supprimer définitivement ton compte ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer mon compte", role: .destructive) { Task { await group.deleteAccount() } }
        } message: {
            Text("Tu quitteras tous tes groupes. Cette action est irréversible.")
        }
    }
}

/// Members of the group, the invitation to send, leaving.
struct GroupMembersView: View {
    @EnvironmentObject private var group: GroupSession
    @State private var confirmLeave = false
    @State private var confirmRotate = false

    var body: some View {
        List {
            Section("Membres") {
                ForEach(group.members) { member in
                    HStack(spacing: 12) {
                        FriendBadge(name: member.name, size: 32)
                        Text(member.name)
                        if member.id == group.userId { Text("(moi)").foregroundStyle(.secondary) }
                        Spacer()
                        if member.isOwner { Text("Créateur").font(.caption.bold()).foregroundStyle(Theme.accent) }
                    }
                    .swipeActions(edge: .trailing) {
                        if group.isOwner, member.id != group.userId {
                            Button("Retirer", role: .destructive) { Task { await group.remove(member) } }
                        }
                    }
                }
            }
            if let current = group.currentGroup {
                Section {
                    if let url = group.inviteURL {
                        ShareLink(item: url, subject: Text("Rejoins mon groupe Moto Road"),
                                  message: Text("Rejoins mon groupe Moto Road « \(current.name) » : ouvre ce lien sur ton iPhone (ou copie ce message, puis « Coller l'invitation » dans l'onglet Groupe). Code : \(Self.spaced(current.inviteCode))")) {
                            GroupRow(title: "Inviter un ami", icon: "square.and.arrow.up", tint: Theme.ok,
                                     subtitle: "Envoie le lien : un seul geste règle tout chez lui")
                        }
                    }
                    GroupRow(title: "Code", icon: "number", tint: .gray, value: Self.spaced(current.inviteCode))
                    if group.isOwner {
                        Button { confirmRotate = true } label: { Label("Changer le code d'invitation", systemImage: "arrow.triangle.2.circlepath") }
                    }
                } header: {
                    Text("Invitation")
                } footer: {
                    Text("Quiconque a le lien ou le code peut rejoindre le groupe (10 motards au plus). Change le code si tu veux fermer l'accès.")
                }
            }
            Section {
                Button(role: .destructive) { confirmLeave = true } label: {
                    Label("Quitter le groupe", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            if let error = group.lastError { Section { Text(error).foregroundStyle(Theme.camera) } }
        }
        .motoList()
        .tint(Theme.accent)
        .navigationTitle("Membres")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Quitter « \(group.currentGroup?.name ?? "") » ?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Quitter le groupe", role: .destructive) { Task { await group.leaveCurrentGroup() } }
        } message: {
            Text("Ta position disparaît de leur carte. Tu pourras revenir avec un code.")
        }
        .confirmationDialog("Changer le code ?", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("Changer le code", role: .destructive) { Task { await group.rotateInvite() } }
        } message: {
            Text("L'ancien lien et l'ancien code ne marcheront plus.")
        }
    }

    /// « K7M2 QX4P »: easier to read out loud.
    static func spaced(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return "\(code.prefix(4)) \(code.suffix(4))"
    }
}
