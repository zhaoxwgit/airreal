import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as p;

/// 单条页面路由配置
class PageRoute {
  final String route;
  final File file;
  final String? contentType;

  PageRoute(this.route, this.file, this.contentType);
}

/// 静态目录映射配置
class StaticDir {
  final String urlPrefix;
  final Directory dir;

  StaticDir(this.urlPrefix, this.dir);
}

/// 解析后的服务器配置
class ServerConfig {
  final InternetAddress host;
  final int port;
  final List<StaticDir> staticDirs;
  final List<PageRoute> pages;
  final File? notFound;

  ServerConfig({
    required this.host,
    required this.port,
    required this.staticDirs,
    required this.pages,
    this.notFound,
  });

  /// 从 YAML 文件加载配置
  factory ServerConfig.load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('配置文件不存在: $path');
      exit(1);
    }

    final YamlMap root = loadYaml(file.readAsStringSync()) as YamlMap;

    final YamlMap server = root['server'] as YamlMap;
    final hostStr = server['host']?.toString() ?? '127.0.0.1';
    final port = int.parse(server['port']?.toString() ?? '8080');

    final List<StaticDir> staticDirs = [];
    final YamlList? staticList = root['static_dirs'] as YamlList?;
    if (staticList != null) {
      for (final item in staticList) {
        final m = item as YamlMap;
        staticDirs.add(StaticDir(
          m['url'].toString(),
          Directory(m['dir'].toString()),
        ));
      }
    }

    final List<PageRoute> pages = [];
    final YamlList? pageList = root['pages'] as YamlList?;
    if (pageList != null) {
      for (final item in pageList) {
        final m = item as YamlMap;
        pages.add(PageRoute(
          m['route'].toString(),
          File(m['file'].toString()),
          m['content_type']?.toString(),
        ));
      }
    }

    final notFoundPath = root['not_found']?.toString();
    final notFoundFile =
        notFoundPath != null ? File(notFoundPath) : null;

    return ServerConfig(
      host: InternetAddress(hostStr),
      port: port,
      staticDirs: staticDirs,
      pages: pages,
      notFound: notFoundFile,
    );
  }
}

/// 按文件扩展名推断 MIME 类型
String guessMimeType(String path) {
  final ext = p.extension(path).toLowerCase();
  switch (ext) {
    case '.html':
    case '.htm':
      return 'text/html; charset=utf-8';
    case '.css':
      return 'text/css; charset=utf-8';
    case '.js':
      return 'application/javascript; charset=utf-8';
    case '.json':
      return 'application/json; charset=utf-8';
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.gif':
      return 'image/gif';
    case '.svg':
      return 'image/svg+xml';
    case '.ico':
      return 'image/x-icon';
    case '.txt':
      return 'text/plain; charset=utf-8';
    default:
      return 'application/octet-stream';
  }
}

/// 规范化 URL 路径
String normalizePath(Uri uri) {
  final pth = uri.path;
  return pth.isEmpty ? '/' : pth;
}

Future<void> main(List<String> args) async {
  final configPath = args.isNotEmpty ? args.first : 'config.yaml';
  final config = ServerConfig.load(configPath);

  final server = await HttpServer.bind(config.host, config.port);
  stdout.writeln('静态服务器已启动: http://${config.host.address}:${config.port}');
  stdout.writeln('配置文件: $configPath');
  stdout.writeln('  路由数: ${config.pages.length}');
  stdout.writeln('  静态目录数: ${config.staticDirs.length}');
  stdout.writeln('按 Ctrl+C 停止...');

  await for (final request in server) {
    await handleRequest(request, config);
  }
}

Future<void> handleRequest(HttpRequest request, ServerConfig config) async {
  final path = normalizePath(request.uri);
  final response = request.response;

  try {
    // 1. 优先匹配静态目录
    for (final sd in config.staticDirs) {
      if (path == sd.urlPrefix || path.startsWith('${sd.urlPrefix}/')) {
        await serveStatic(sd, path, request, response);
        return;
      }
    }

    // 2. 匹配页面路由
    for (final page in config.pages) {
      if (path == page.route) {
        await servePage(page, request, response);
        return;
      }
    }

    // 3. 兜底 404
    await serveNotFound(config, request, response);
  } catch (e, st) {
    stderr.writeln('处理请求出错 [$path]: $e\n$st');
    response.statusCode = HttpStatus.internalServerError;
    response.headers.contentType = ContentType.text;
    response.write('500 Internal Server Error');
    await response.close();
  }
}

/// 提供静态文件服务
Future<void> serveStatic(
  StaticDir sd,
  String path,
  HttpRequest request,
  HttpResponse response,
) async {
  // 去掉 url 前缀,拼出磁盘路径
  var relPath = path.substring(sd.urlPrefix.length);
  if (relPath.startsWith('/')) relPath = relPath.substring(1);
  final fsPath = p.normalize(p.join(sd.dir.path, relPath));

  final type = FileSystemEntity.typeSync(fsPath);
  File file;

  if (type == FileSystemEntityType.directory) {
    // 目录则尝试 index.html
    file = File(p.join(fsPath, 'index.html'));
    if (!file.existsSync()) {
      await respondText(response, HttpStatus.forbidden,
          '403 Forbidden: Directory listing disabled');
      return;
    }
  } else if (type == FileSystemEntityType.file) {
    file = File(fsPath);
  } else {
    await respondText(
        response, HttpStatus.notFound, '404 Not Found: $path');
    logRequest(request, response.statusCode, 'static miss -> $fsPath');
    return;
  }

  response.headers.contentType = ContentType.parse(guessMimeType(file.path));
  await file.openRead().cast<List<int>>().pipe(response);
  logRequest(request, response.statusCode, file.path);
}

/// 提供页面路由文件
Future<void> servePage(
    PageRoute page, HttpRequest request, HttpResponse response) async {
  if (!page.file.existsSync()) {
    await respondText(response, HttpStatus.notFound,
        '404 Not Found: 配置的页面文件不存在 -> ${page.file.path}');
    return;
  }

  final contentType = page.contentType ?? guessMimeType(page.file.path);
  response.headers.contentType = ContentType.parse(contentType);
  await page.file.openRead().cast<List<int>>().pipe(response);
  logRequest(request, response.statusCode, '${page.route} -> ${page.file.path}');
}

/// 404 兜底
Future<void> serveNotFound(
    ServerConfig config, HttpRequest request, HttpResponse response) async {
  response.statusCode = HttpStatus.notFound;

  if (config.notFound != null && config.notFound!.existsSync()) {
    response.headers.contentType =
        ContentType.parse(guessMimeType(config.notFound!.path));
    await config.notFound!.openRead().cast<List<int>>().pipe(response);
  } else {
    await respondText(response, HttpStatus.notFound, '404 Not Found',
        setStatusCode: false);
  }
  logRequest(request, response.statusCode, '404 fallback');
}

/// 写入纯文本响应
Future<void> respondText(
  HttpResponse response,
  int statusCode,
  String body, {
  bool setStatusCode = true,
}) async {
  if (setStatusCode) response.statusCode = statusCode;
  response.headers.contentType = ContentType.text;
  response.write(body);
  await response.close();
}

void logRequest(HttpRequest? request, int statusCode, String detail) {
  final method = request?.method ?? 'GET';
  final uri = request?.uri.toString() ?? detail;
  stdout.writeln('[${DateTime.now().toIso8601String()}] '
      '$statusCode $method $uri  ($detail)');
}
