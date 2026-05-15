//
//  BackupTrackItem.swift
//  Aidoku
//
//  Created by Skitty on 7/21/22.
//

import CoreData

struct BackupTrackItem: Codable, Hashable {
    var id: String
    var trackerId: String
    var mangaId: String
    var sourceId: String
    var title: String?
    var offset: Int

    init(
        id: String,
        trackerId: String,
        mangaId: String,
        sourceId: String,
        title: String?,
        offset: Int = 0
    ) {
        self.id = id
        self.trackerId = trackerId
        self.mangaId = mangaId
        self.sourceId = sourceId
        self.title = title
        self.offset = offset
    }

    init(trackObject: TrackObject) {
        id = trackObject.id ?? ""
        trackerId = trackObject.trackerId ?? ""
        mangaId = trackObject.mangaId ?? ""
        sourceId = trackObject.sourceId ?? ""
        title = trackObject.title
        offset = Int(trackObject.offset)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        trackerId = try c.decode(String.self, forKey: .trackerId)
        mangaId = try c.decode(String.self, forKey: .mangaId)
        sourceId = try c.decode(String.self, forKey: .sourceId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }

    func toObject(context: NSManagedObjectContext? = nil) -> TrackObject {
        let obj: TrackObject
        if let context = context {
            obj = TrackObject(context: context)
        } else {
            obj = TrackObject()
        }
        obj.id = id
        obj.trackerId = trackerId
        obj.mangaId = mangaId
        obj.sourceId = sourceId
        obj.title = title
        obj.offset = Int32(offset)
        return obj
    }
}
