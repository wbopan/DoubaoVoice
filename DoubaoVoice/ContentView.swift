//
//  ContentView.swift
//  DoubaoVoice
//
//  Main UI for voice transcription
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var viewModel = TranscriptionViewModel.shared

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text("DoubaoVoice")
                .font(.largeTitle)
                .fontWeight(.bold)

            // Status indicator
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)

                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Transcription text area
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading) {
                        if viewModel.transcribedText.isEmpty && !viewModel.isRecording {
                            Text("Transcribed text will appear here...")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            Text(viewModel.transcribedText)
                                .font(.body)
                                .textSelection(.enabled)
                                .id("transcriptionText")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .onChange(of: viewModel.transcribedText) {
                        // Auto-scroll to bottom when text updates
                        withAnimation {
                            proxy.scrollTo("transcriptionText", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color(.textBackgroundColor).opacity(0.5))
            .cornerRadius(12)

            // Error message
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            // Record/Stop button
            Button(action: {
                viewModel.toggleRecording()
            }) {
                HStack {
                    Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title)

                    Text(viewModel.isRecording ? "Stop Recording" : "Start Recording")
                        .font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(viewModel.isRecording ? Color.red : Color.blue)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
        .padding(30)
        .frame(minWidth: 500, minHeight: 400)
    }

    // Status indicator color
    private var statusColor: Color {
        if viewModel.isRecording {
            return .red
        } else if viewModel.errorMessage != nil {
            return .orange
        } else if viewModel.statusMessage.contains("Connected") || viewModel.statusMessage.contains("Completed") {
            return .green
        } else {
            return .gray
        }
    }
}

#Preview {
    ContentView()
}
