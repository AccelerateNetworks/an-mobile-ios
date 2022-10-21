//
//  FileUtils.swift
//  Linhome
//
//  Created by Christophe Deschamps on 24/02/2020.
//  Copyright © 2020 Belledonne communications. All rights reserved.
//

import UIKit
import linphonesw

@objc class FileUtil: NSObject {
	public class func bundleFilePath(_ file: NSString) -> String? {
		return Bundle.main.path(forResource: file.deletingPathExtension, ofType: file.pathExtension)
	}
	
	public class func bundleFilePathAsUrl(_ file: NSString) -> URL? {
		if let bPath = bundleFilePath(file)  {
			return URL.init(fileURLWithPath: bPath)
		}
		return nil
	}
	
	public class func documentsDirectory() -> URL {
		let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
		let documentsDirectory = paths[0]
		return documentsDirectory
	}
	
	public class func libraryDirectory() -> URL {
		let paths = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
		let documentsDirectory = paths[0]
		return documentsDirectory
	}
	
	public class func sharedContainerUrl(appGroupName:String) -> URL {
		return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)!
	}
	
	
	@objc public class func ensureDirectoryExists(path:String) {
		if !FileManager.default.fileExists(atPath: path) {
			do {
				try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
			} catch {
				print(error)
			}
		}
	}
	
	public class func ensureFileExists(path:String) {
		if !FileManager.default.fileExists(atPath: path) {
			FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
		}
	}
	
	public class func fileExists(path:String) -> Bool {
		return FileManager.default.fileExists(atPath: path)
	}
	
	public class func fileExistsAndIsNotEmpty(path:String) -> Bool {
		guard FileManager.default.fileExists(atPath: path) else {return false}
		do {
			let attribute = try FileManager.default.attributesOfItem(atPath: path)
			if let size = attribute[FileAttributeKey.size] as? NSNumber {
				return size.doubleValue > 0
			} else {
				return false
			}
		} catch {
			print(error)
			return false
		}
	}
		
	public class func write(string:String, toPath:String) {
		do {
			try string.write(to: URL(fileURLWithPath:toPath), atomically: true, encoding: String.Encoding.utf8)
		} catch {
			print(error)
		}
	}
	
	public class func delete(path:String) {
		do {
			try FileManager.default.removeItem(atPath: path)
			print("FIle \(path) was removed")
		} catch {
			print("Error deleting file at path \(path) error is \(error)")
		}
	}
	
	public class func mkdir(path:String) {
		do {
			try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
			print("Dir \(path) was created")
		} catch {
			print("Error creating dir at path \(path) error is \(error)")
		}
	}
	
	
	
	public class func copy(_ fromPath:String, _ toPath: String, overWrite:Bool) {
		do {
			if (overWrite && fileExists(path: toPath)) {
				delete(path: toPath)
			}
			try FileManager.default.copyItem(at:  URL(fileURLWithPath:fromPath), to:  URL(fileURLWithPath:toPath))
		} catch {
			print(error)
		}
	}
	
	
	// For debugging
	
	public class func showListOfFilesInSharedDir(appGroupName:String) {
		let fileManager = FileManager.default
		do {
			let fileURLs = try fileManager.contentsOfDirectory(at:  FileUtil.sharedContainerUrl(appGroupName: appGroupName), includingPropertiesForKeys: nil)
			fileURLs.forEach{print($0)}
		} catch {
			print("Error while enumerating files \(error.localizedDescription)")
		}
	}
	
}
