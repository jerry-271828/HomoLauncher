import { http } from '@kit.NetworkKit'
import { fileIo } from '@kit.CoreFileKit'
import { CompatibilityRule, MinecraftVersion } from '../model/MinecraftVersion'

// 版本清单条目
export interface VersionManifestEntry {
  id: string
  type: string
  url: string
  releaseTime: string
}

interface VersionManifest {
  versions: VersionManifestEntry[]
}

interface AssetObject {
  hash: string
  size: number
}

interface AssetIndexData {
  objects: Record<string, AssetObject>
}

interface DownloadTaskItem {
  url: string
  dest: string
  size: number
  name: string
}

export class CancelledError extends Error {
  constructor() {
    super('已取消')
    this.name = 'CancelledError'
  }
}

const OFFICIAL_MANIFEST = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
const MIRROR_MANIFEST = 'https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json'
const MIRROR_HOST = 'https://bmclapi2.bangbang93.com'
const LIBRARIES_PREFIX = 'https://libraries.minecraft.net/'
const RESOURCES_PREFIX = 'https://resources.download.minecraft.net/'
const MOJANG_HOST_REGEX = /^https:\/\/(piston-meta|piston-data|launcher|launchermeta)\.mojang\.com/

// 并发下载数
const CONCURRENCY = 8

/**
 * 按用户选择的下载源解析文件地址
 * useMirror=true 时把 Mojang 官方地址映射为 BMCLAPI 镜像地址
 */
export function resolveUrl(officialUrl: string, useMirror: boolean): string {
  if (!useMirror) {
    return officialUrl
  }
  if (officialUrl.startsWith(LIBRARIES_PREFIX)) {
    return MIRROR_HOST + '/maven/' + officialUrl.substring(LIBRARIES_PREFIX.length)
  }
  if (officialUrl.startsWith(RESOURCES_PREFIX)) {
    return MIRROR_HOST + '/assets/' + officialUrl.substring(RESOURCES_PREFIX.length)
  }
  return officialUrl.replace(MOJANG_HOST_REGEX, MIRROR_HOST)
}

export async function fetchJson<T>(url: string): Promise<T> {
  const request = http.createHttp()
  try {
    const response = await request.request(url, {
      method: http.RequestMethod.GET,
      header: { 'Accept': 'application/json' },
      connectTimeout: 15000,
      readTimeout: 30000,
    })
    if (response.responseCode !== 200) {
      throw new Error(`HTTP ${response.responseCode}`)
    }
    return JSON.parse(response.result as string) as T
  } finally {
    request.destroy()
  }
}

// 获取版本清单（按所选源）
export async function fetchManifest(useMirror: boolean): Promise<VersionManifestEntry[]> {
  const manifest = await fetchJson<VersionManifest>(useMirror ? MIRROR_MANIFEST : OFFICIAL_MANIFEST)
  return manifest.versions
}

async function ensureParentDir(path: string): Promise<void> {
  const index = path.lastIndexOf('/')
  if (index <= 0) {
    return
  }
  const dir = path.substring(0, index)
  if (!await fileIo.access(dir)) {
    await fileIo.mkdir(dir, true)
  }
}

/**
 * 下载单个文件到本地
 * 已存在且大小一致则跳过；expectedSize<=0 时不做大小校验（总是重新下载）
 */
async function downloadFile(url: string, destPath: string, expectedSize: number): Promise<void> {
  if (expectedSize > 0) {
    try {
      if (await fileIo.access(destPath)) {
        const stat = await fileIo.stat(destPath)
        if (stat.size === expectedSize) {
          return
        }
      }
    } catch (_) {
      // 无法访问则按不存在处理，继续下载
    }
  }
  await ensureParentDir(destPath)
  const request = http.createHttp()
  try {
    const response = await request.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 120000,
    })
    if (response.responseCode !== 200) {
      throw new Error(`HTTP ${response.responseCode}`)
    }
    const data = response.result as ArrayBuffer
    if (expectedSize > 0 && data.byteLength !== expectedSize) {
      throw new Error(`文件大小不符 ${data.byteLength}/${expectedSize}`)
    }
    const tmpPath = destPath + '.tmp'
    const file = await fileIo.open(tmpPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
    try {
      await fileIo.write(file.fd, data)
    } finally {
      await fileIo.close(file)
    }
    await fileIo.rename(tmpPath, destPath)
  } finally {
    request.destroy()
  }
}

/**
 * Mojang rules 评估：os.name 固定按 linux（与启动参数 -Dos.name=Linux 一致）
 * 默认 allow，匹配的最后一条规则决定结果
 */
export function rulesAllow(rules?: CompatibilityRule[]): boolean {
  if (!rules || rules.length === 0) {
    return true
  }
  let allowed = false
  for (const rule of rules) {
    const osMatch = !rule.os || !rule.os.name || rule.os.name === 'linux'
    if (!osMatch) {
      continue
    }
    allowed = rule.action === 'allow'
  }
  return allowed
}

export type ProgressCallback = (done: number, total: number, current: string) => void

/**
 * 下载并安装一个原版版本到游戏目录
 * @returns 安装完成的版本 id
 */
export async function installVersion(
  entry: VersionManifestEntry,
  gameRootDir: string,
  useMirror: boolean,
  onProgress: ProgressCallback,
  isCancelled: () => boolean
): Promise<string> {
  // 1. 版本 json（先在内存解析成功，后面再落盘）
  const version = await fetchJson<MinecraftVersion>(resolveUrl(entry.url, useMirror))
  const id = version.id ?? entry.id
  const versionDir = gameRootDir + 'versions/' + id + '/'

  const tasks: DownloadTaskItem[] = []
  const seen: Set<string> = new Set()
  const addTask = (url: string, dest: string, size: number, name: string) => {
    if (seen.has(dest)) {
      return
    }
    seen.add(dest)
    tasks.push({ url: resolveUrl(url, useMirror), dest, size, name })
  }

  addTask(entry.url, versionDir + id + '.json', 0, id + '.json')

  // 2. 客户端 jar
  if (version.downloads?.client) {
    const client = version.downloads.client
    addTask(client.url, versionDir + id + '.jar', client.size, id + '.jar')
  }

  // 3. 依赖库（只取 artifact，natives 由应用自带的 JRE/LWJGL 提供）
  for (const lib of version.libraries ?? []) {
    if (!rulesAllow(lib.rules)) {
      continue
    }
    const artifact = lib.downloads?.artifact
    if (artifact) {
      addTask(artifact.url, gameRootDir + 'libraries/' + artifact.path, artifact.size, artifact.path)
    }
  }

  // 4. 资源索引与资源文件
  if (version.assetIndex) {
    const indexDest = gameRootDir + 'assets/indexes/' + version.assetIndex.id + '.json'
    addTask(version.assetIndex.url, indexDest, version.assetIndex.size, version.assetIndex.id + '.json')
    const indexData = await fetchJson<AssetIndexData>(resolveUrl(version.assetIndex.url, useMirror))
    const objects = indexData.objects ?? {}
    for (const key of Object.keys(objects)) {
      const obj = objects[key]
      const prefix = obj.hash.substring(0, 2)
      addTask(RESOURCES_PREFIX + prefix + '/' + obj.hash,
        gameRootDir + 'assets/objects/' + prefix + '/' + obj.hash, obj.size, key)
    }
  }

  // 5. 日志配置
  const logFile = version.logging?.client?.file
  if (logFile) {
    addTask(logFile.url, gameRootDir + 'assets/log_configs/' + logFile.id, logFile.size, logFile.id)
  }

  // 6. 并发下载（单线程事件循环，cursor 自增无竞争）
  const total = tasks.length
  let cursor = 0
  let done = 0
  let failedMessage: string | undefined = undefined
  const worker = async (): Promise<void> => {
    while (true) {
      if (isCancelled() || failedMessage) {
        return
      }
      const index = cursor++
      if (index >= tasks.length) {
        return
      }
      const task = tasks[index]
      try {
        await downloadFile(task.url, task.dest, task.size)
        done++
        onProgress(done, total, task.name)
      } catch (e) {
        failedMessage = `${task.name}: ${(e as Error).message}`
        return
      }
    }
  }
  const workers: Promise<void>[] = []
  for (let i = 0; i < Math.min(CONCURRENCY, tasks.length); i++) {
    workers.push(worker())
  }
  await Promise.all(workers)

  if (isCancelled()) {
    throw new CancelledError()
  }
  const message = failedMessage
  if (message) {
    throw new Error(message)
  }
  return id
}
