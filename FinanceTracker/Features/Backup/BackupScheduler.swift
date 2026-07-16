import Foundation
import os
import SwiftData

#if os(macOS)

@MainActor
enum BackupScheduler {
    static func runIfNeeded(context: ModelContext) async {
        let fm = FileManager.default
        let appSupport: URL
        do {
            appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        } catch {
            Logger.app.error("BackupScheduler: no se resolvió Application Support: \(error.localizedDescription)")
            return
        }
        let backupsDir = appSupport.appendingPathComponent("FinanceTracker/Backups")

        do {
            try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        } catch {
            Logger.app.error("BackupScheduler: no se pudo crear \(backupsDir.path): \(error.localizedDescription)")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let existingBundles = backupURLs(in: backupsDir)
        if let mostRecent = existingBundles.last {
            let attrs: Date
            do {
                attrs = try fm.attributesOfItem(atPath: mostRecent.path)[.modificationDate] as? Date ?? .distantPast
            } catch {
                attrs = .distantPast
            }
            if Date.now.timeIntervalSince(attrs) < 86400 {
                Logger.app.debug("BackupScheduler: último backup tiene <24h (\(mostRecent.lastPathComponent)); se omite.")
                return
            }
            Logger.app.info("BackupScheduler: último backup \(mostRecent.lastPathComponent) tiene >24h; generando uno nuevo.")
        }

        let timestamp = formatter.string(from: Date.now)
        let bundleURL = backupsDir.appendingPathComponent("\(timestamp).ftbackup")

        do {
            try await BackupArchive.export(to: bundleURL, from: context)
        } catch {
            // Antes este error se tragaba en silencio: el backup fallaba y no quedaba
            // evidencia, así que los backups automáticos se estancaban sin aviso.
            Logger.app.error("BackupScheduler: export falló para \(bundleURL.lastPathComponent): \(error.localizedDescription)")
            return
        }

        Logger.app.info("BackupScheduler: backup generado \(bundleURL.lastPathComponent).")
        pruneSnapshots(in: backupsDir)
    }

    static func pruneSnapshots(in directory: URL) {
        let fm = FileManager.default
        // backupURLs devuelve mtime ascendente; aquí queremos DESCENDENTE para que los
        // buckets (diario/semanal/mensual) se llenen con el bundle MÁS RECIENTE de cada
        // período, no con el más viejo. Iterar ascendente hacía que un bundle recién
        // creado quedara fuera de los 7 diarios (ya ocupados por viejos) y de los
        // buckets semana/mes (ya con representante viejo), y terminaba BORRADO por la
        // poda — el scheduler generaba su backup y lo eliminaba en la línea siguiente.
        let bundles = backupURLs(in: directory).sorted { urlBefore($0, $1, fm: fm) }.reversed()
        let bundlesArray = Array(bundles)
        guard bundlesArray.count > 1 else { return }

        let calendar = Calendar(identifier: .gregorian)

        // El más reciente SIEMPRE se conserva (es el backup que acaba de crear el
        // scheduler, o el último bueno). Esto es la red de seguridad: ningún bug de
        // bucketing puede borrarlo.
        guard let mostRecent = bundlesArray.first else { return }
        var keep: Set<URL> = [mostRecent]

        var dailyCount = 0
        var weeklyBuckets: [Int: URL] = [:]
        var monthlyBuckets: [Int: URL] = [:]

        for url in bundlesArray {
            guard let modDate = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else { continue }

            // Los 7 más recientes como retención diaria.
            if dailyCount < 7 {
                keep.insert(url)
                dailyCount += 1
            }

            let weekOfYear = calendar.component(.weekOfYear, from: modDate)
            let yearForWeek = calendar.component(.yearForWeekOfYear, from: modDate)
            let weekKey = yearForWeek * 100 + weekOfYear
            // Primer match en orden DESCENDENTE = el más reciente de esa semana.
            if weeklyBuckets[weekKey] == nil {
                weeklyBuckets[weekKey] = url
            }

            let month = calendar.component(.month, from: modDate)
            let year = calendar.component(.year, from: modDate)
            let monthKey = year * 100 + month
            if monthlyBuckets[monthKey] == nil {
                monthlyBuckets[monthKey] = url
            }
        }

        // Conservar los 4 buckets semanales y 12 mensuales MÁS RECIENTES (suffix de
        // los valores ordenados ascendentemente = los más nuevos).
        let weeklyValues = Array(weeklyBuckets.values).sorted { urlBefore($0, $1, fm: fm) }
        for url in weeklyValues.suffix(4) {
            keep.insert(url)
        }
        let monthlyValues = Array(monthlyBuckets.values).sorted { urlBefore($0, $1, fm: fm) }
        for url in monthlyValues.suffix(12) {
            keep.insert(url)
        }

        for url in bundlesArray {
            if !keep.contains(url) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func backupURLs(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let bundles = contents.filter { $0.pathExtension == "ftbackup" }
        return bundles.sorted { urlBefore($0, $1, fm: fm) }
    }

    private static func urlBefore(_ a: URL, _ b: URL, fm: FileManager) -> Bool {
        let dateA = (try? fm.attributesOfItem(atPath: a.path)[.modificationDate] as? Date) ?? .distantPast
        let dateB = (try? fm.attributesOfItem(atPath: b.path)[.modificationDate] as? Date) ?? .distantPast
        return dateA < dateB
    }
}

#endif
