import PhotosUI
import SwiftUI

struct CardEditorImageSection: View {
    @Binding var draft: StudyCardDraft
    @Binding var selectedPhotoItem: PhotosPickerItem?
    let stagedPhotoPreview: UIImage?
    let hasStagedPhoto: Bool
    let promptImagePreview: UIImage?
    let answerImagePreview: UIImage?
    let promptImageLocalURL: URL?
    let answerImageLocalURL: URL?
    let hasExistingMediaTarget: Bool
    let showsMissingCurrentImage: Bool
    let supportsUserPhoto: Bool
    let creationKind: StudyCardCreationKind
    let isRegeneratingImage: Bool
    let isBusy: Bool
    let onStagePhoto: (UIImage) -> Void
    let onPhotoLoadError: () -> Void
    let onRemovePhoto: () -> Void
    let onTakePhoto: () -> Void
    let onPlacementChange: (StudyCardDraft.ImagePlacement) -> Void
    let onRegenerate: () -> Void

    var body: some View {
        Section("Image") {
            if let stagedPhotoPreview {
                CardEditorImagePreview(image: stagedPhotoPreview, label: "Selected photo")
            }
            if let promptImagePreview {
                CardEditorImagePreview(
                    image: promptImagePreview,
                    label: answerImageLocalURL == promptImageLocalURL
                        ? "Current card image"
                        : "Front image"
                )
            }
            if let answerImagePreview,
               answerImageLocalURL != promptImageLocalURL {
                CardEditorImagePreview(image: answerImagePreview, label: "Back image")
            } else if showsMissingCurrentImage, promptImagePreview == nil {
                Text("No current image")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Image prompt")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    "Describe the image to generate",
                    text: $draft.imagePrompt,
                    axis: .vertical
                )
                .lineLimit(2...6)
                .disabled(isRegeneratingImage)
                Text("\(trimmedPrompt.count)/1,000")
                    .font(.caption)
                    .foregroundStyle(trimmedPrompt.count > 1_000 ? .red : .secondary)
            }

            Picker("Image placement", selection: $draft.imagePlacement) {
                ForEach(StudyCardDraft.ImagePlacement.allCases) { placement in
                    Text(placement.title).tag(placement)
                }
            }
            .disabled(isRegeneratingImage)
            .onChange(of: draft.imagePlacement) { _, placement in
                onPlacementChange(placement)
            }

            if supportsUserPhoto {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }
                .onChange(of: selectedPhotoItem) { _, item in
                    guard let item else { return }
                    Task {
                        do {
                            guard
                                let data = try await item.loadTransferable(type: Data.self),
                                let image = UIImage(data: data)
                            else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            onStagePhoto(image)
                        } catch {
                            onPhotoLoadError()
                        }
                    }
                }

                Button(action: onTakePhoto) {
                    Label("Take Photo", systemImage: "camera")
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                if hasStagedPhoto {
                    Button("Remove Selected Photo", role: .destructive, action: onRemovePhoto)
                    Text("The selected photo will upload when you save the card.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if hasExistingMediaTarget {
                Button(action: onRegenerate) {
                    if isRegeneratingImage {
                        Label("Regenerating image…", systemImage: "photo.badge.arrow.down")
                    } else {
                        Label("Regenerate Image", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(
                    isBusy
                        || draft.imagePlacement == .none
                        || trimmedPrompt.isEmpty
                        || trimmedPrompt.count > 1_000
                )
            } else {
                Text(
                    creationKind == .productionImage
                        ? "Tap Prepare to let learning-os fill the draft before generating its image."
                        : "An image can be generated after this card has synced."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var trimmedPrompt: String {
        draft.imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CardEditorAnswerAudioSection: View {
    @Binding var draft: StudyCardDraft
    let player: StudyAudioPlayer
    let answerAudioLocalURL: URL?
    let answerAudioTrackID: String
    let hasExistingMediaTarget: Bool
    let creationKind: StudyCardCreationKind
    let isRegeneratingAudio: Bool
    let isBusy: Bool
    let onRegenerate: () -> Void

    var body: some View {
        Section("Answer audio") {
            if hasExistingMediaTarget {
                if let answerAudioLocalURL {
                    Button {
                        if player.isCurrent(answerAudioTrackID), player.isPlaying {
                            player.stop()
                        } else {
                            player.play(url: answerAudioLocalURL, trackID: answerAudioTrackID)
                        }
                    } label: {
                        Label(
                            player.isCurrent(answerAudioTrackID) && player.isPlaying
                                ? "Stop current audio"
                                : "Play current audio",
                            systemImage: player.isCurrent(answerAudioTrackID) && player.isPlaying
                                ? "stop.fill"
                                : "play.fill"
                        )
                    }
                    .disabled(player.isBlockedByLongFormAudio || isBusy)
                } else {
                    Text("No current audio")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Voice", selection: $draft.answerAudioVoiceId) {
                if !StudyAnswerVoice.japanese.contains(
                    where: { $0.id == draft.answerAudioVoiceId }
                ) {
                    Text("Current voice").tag(draft.answerAudioVoiceId)
                }
                ForEach(StudyAnswerVoice.japanese) { voice in
                    Text("\(voice.name) — \(voice.detail)").tag(voice.id)
                }
            }

            TextField(
                "Phonetic audio override (optional)",
                text: $draft.answerAudioTextOverride,
                axis: .vertical
            )
            .lineLimit(1...4)

            if hasExistingMediaTarget {
                Button(action: onRegenerate) {
                    if isRegeneratingAudio {
                        Label("Regenerating audio…", systemImage: "waveform")
                    } else {
                        Label("Regenerate Audio", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isBusy)
            } else {
                Text(
                    creationKind == .audioRecognition
                        ? "Tap Prepare to let learning-os fill the draft before generating its prompt audio."
                        : "Audio can be generated after this card has synced."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CardEditorImagePreview: View {
    let image: UIImage
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityLabel(label)
        }
    }
}

struct CameraImagePicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate,
        UIImagePickerControllerDelegate
    {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
