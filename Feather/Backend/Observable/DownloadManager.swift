//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit.UIImpactFeedbackGenerator
import BackgroundTasks

class Download: Identifiable, @unchecked Sendable {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	
	var overallProgress: Double {
		onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}
	
	var task: URLSessionDownloadTask?
	
	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	let sourceProvenance: SourceAppProvenance?
	var importCompletion: ((Result<String, Error>) -> Void)?
	
	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false,
		sourceProvenance: SourceAppProvenance? = nil
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.sourceProvenance = sourceProvenance
		self.fileName = url.lastPathComponent
	}
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()
	
	@Published var downloads: [Download] = []
	
	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}
	
	private var _session: URLSession!
	
	#if !targetEnvironment(macCatalyst)
	private func _updateBackgroundAudioState() {
		if #unavailable(iOS 26.0){
			if !downloads.isEmpty {
				BackgroundAudioManager.shared.start()
			} else  {
				BackgroundAudioManager.shared.stop()
			}
		}
	}
	#endif
	
	override init() {
		super.init()
		let configuration = URLSessionConfiguration.default
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
	}
	
	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		sourceProvenance: SourceAppProvenance? = nil,
		onImport: ((Result<String, Error>) -> Void)? = nil
	) -> Download {
		if let existingDownload = downloads.first(where: {
			!$0.onlyArchiving && $0.url == url && $0.sourceProvenance == sourceProvenance
		}) {
			if let onImport { existingDownload.importCompletion = onImport }
			return existingDownload
		}
		
		let download = Download(id: id, url: url, sourceProvenance: sourceProvenance)
		download.importCompletion = onImport
		
		let task = _session.downloadTask(with: url)
		download.task = task
		
		downloads.append(download)
		task.resume()
		
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
		} else {
			_updateBackgroundAudioState()
		}
		#endif
		
		return download
	}
	
	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif
		
		return download
	}
	
	func cancelDownload(_ download: Download) {
		download.task?.cancel()
		_finish(download, result: .failure(CancellationError()))
	}
	
	func isManualDownload(_ string: String) -> Bool {
		return string.contains("FeatherManualDownload")
	}
	
	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}
	
	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}

	private func _finish(_ download: Download, result: Result<String, Error>) {
		guard let index = downloads.firstIndex(where: { $0 === download }) else { return }
		downloads.remove(at: index)
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.stopTask(for: download.id, success: (try? result.get()) != nil)
		}
		_updateBackgroundAudioState()
		#endif
		let completion = download.importCompletion
		download.importCompletion = nil
		completion?(result)
	}
}

extension DownloadManager: URLSessionDownloadDelegate {
	
	func importPackageFile(at url: URL, for download: Download, cleanupDirectory: URL? = nil) {
		FR.handlePackageFile(url, download: download) { result in
			if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) }
			if case .failure = result {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)
			}
			self._finish(download, result: result)
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
		
		let files = FileManager.default
		let directory = files.temporaryDirectory.appendingPathComponent("FeatherDownloads", isDirectory: true)
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		
		do {
			if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
				throw URLError(.badServerResponse)
			}
			try files.createDirectory(at: directory, withIntermediateDirectories: true)
			let suggestedName = downloadTask.response?.suggestedFilename ?? download.fileName
			let fileName = (suggestedName as NSString).lastPathComponent
			let destinationURL = directory.appendingPathComponent(["", ".", "..", "/"].contains(fileName) ? "Download.ipa" : fileName)
			try files.moveItem(at: location, to: destinationURL)
			
			importPackageFile(at: destinationURL, for: download, cleanupDirectory: directory)
		} catch {
			try? files.removeItem(at: directory)
			_finish(download, result: .failure(error))
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
		
		DispatchQueue.main.async {
			download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0
			download.bytesDownloaded = totalBytesWritten
			download.totalBytes = totalBytesExpectedToWrite
			
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
			}
			#endif
		}
	}
	
	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard
			let error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
		else {
			return
		}
		
		_finish(download, result: .failure(error))
	}
}
