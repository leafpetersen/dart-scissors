// Copyright 2015 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
library scissors.scissors_transformer;

import 'dart:async';

import 'package:barback/barback.dart';

import 'package:path/path.dart';
import 'package:quiver/check.dart';
import 'package:source_maps/refactor.dart';
import 'package:source_span/source_span.dart';

import 'src/css_pruning.dart';
import 'src/deps_consumer.dart';
import 'src/image_inliner.dart';
import 'src/path_resolver.dart';
import 'src/path_utils.dart';
import 'src/sassc.dart' show runSassC;
import 'src/settings.dart';
import 'src/svg_optimizer.dart';

class _Css {
  final Asset original;
  final Asset content;

  /// The source map between original and content;
  final Asset map;
  _Css({this.original, this.content, this.map}) {
    checkNotNull(content);
  }
}

/// This eager transformer is only used in tests.
/// The *real* transformer is [LazyScissorsTransformer].
class EagerScissorsTransformer extends Transformer
    implements DeclaringTransformer {
  final ScissorsSettings settings;
  String _allowedExtensions;

  EagerScissorsTransformer(this.settings) {
    var exts = ['.css', '.map'];
    if (settings.compileSass.value) exts..add('.sass')..add('.scss');
    if (settings.optimizeSvg.value) exts.add('.svg');
    _allowedExtensions = exts.join(' ');
  }

  EagerScissorsTransformer.asPlugin(BarbackSettings settings)
      : this(new ScissorsSettings.fromSettings(settings));

  @override
  String get allowedExtensions => _allowedExtensions;

  final RegExp _filesToSkipRx =
      new RegExp(r'^_.*?\.scss|.*?\.ess\.s[ac]ss\.css(\.map)?$');

  bool _shouldSkipAsset(AssetId id) {
    var name = basename(id.path);
    return _filesToSkipRx.matchAsPrefix(name) != null;
  }

  @override
  declareOutputs(DeclaringTransform transform) {
    var id = transform.primaryId;
    if (_shouldSkipAsset(id)) return;

    switch (id.extension) {
      case '.svg':
        transform.consumePrimary();
        transform.declareOutput(id);
        break;
      case '.css':
        transform.consumePrimary();
        transform.declareOutput(id);
        transform.declareOutput(id.addExtension('.map'));
        break;
      case '.scss':
      case '.sass':
        transform.consumePrimary();
        transform.declareOutput(id.addExtension('.css'));
        transform.declareOutput(id.addExtension('.css.map'));
        break;
      case '.map':
        transform.consumePrimary();
        break;
    }
  }

  Future<Asset> _optimizeSvg(Transform transform, Asset asset) async {
    var input = await asset.readAsString();
    var output = optimizeSvg(input);
    transform.logger.info(
        'Optimized SVG: ${input.length} chars -> ${output.length} chars',
        asset: asset.id);
    if (settings.verbose.value) {
      transform.logger.info('Optimized SVG content:\n$output', asset: asset.id);
    }
    return new Asset.fromString(asset.id, output);
  }

  Future apply(Transform transform) async {
    var id = transform.primaryInput.id;

    if (_shouldSkipAsset(transform.primaryInput.id)) {
      transform.logger.info("Skipping ${transform.primaryInput.id}");
      return;
    }

    _Css css;
    switch (id.extension) {
      case '.svg':
        checkState(settings.optimizeSvg.value);
        transform
            .addOutput(await _optimizeSvg(transform, transform.primaryInput));
        return;
      case '.css':
        // TODO(ochafik): Import existing .map file if it exists
        // (and parse it + get its original source).
        css = new _Css(content: transform.primaryInput);
        break;
      case '.scss':
      case '.sass':
        checkState(settings.compileSass.value);
        css = await _convertSass(transform, transform.primaryInput);
        if (css == null) return;
        break;
      case '.map':
        transform.consumePrimary();
        return;
    }

    if (settings.pruneCss.value) {
      try {
        String htmlTemplate = await findHtmlTemplate(transform, css.content.id);
        css = await _pruneCss(transform, css, htmlTemplate);
      } catch (e, s) {
        acceptAssetNotFoundException(e, s);
        // No HTML template found: leave the CSS alone!
      }
    }
    if (settings.imageInlining.value != ImageInliningMode.disablePass) {
      css = await _inlineImages(css, transform);
    }

    transform.consumePrimary();

    if (css.original != css.content) {
      if (css.original != null &&
          css.map != null &&
          css.original.id != css.content?.id) {
        transform.addOutput(css.original);
      }
      transform.addOutput(css.content);
      if (css.map != null) transform.addOutput(css.map);
    }
  }

  _time(Transform transform, String title, Future<_Css> action()) async {
    var stopwatch = new Stopwatch()..start();
    try {
      if (settings.isDebug) transform.logger.info('$title...');
      return await action();
    } finally {
      transform.logger
          .info('$title took ${stopwatch.elapsed.inMilliseconds} msec.');
    }
  }

  Future<_Css> _convertSass(Transform transform, Asset scss) =>
      _time(transform, 'Running sassc on ${scss.id}', () async {
        // Mark transitive SASS @imports as barback dependencies.
        var depsConsumption = consumeTransitiveSassDeps(transform, scss);

        var result = await runSassC(scss,
            isDebug: settings.isDebug, settings: await settings.sasscSettings);
        result.logMessages(transform);

        await depsConsumption;

        if (!result.success) return null;
        return new _Css(original: scss, content: result.css, map: result.map);
      });

  Future<_Css> _pruneCss(Transform transform, _Css css, String htmlTemplate) =>
      _time(transform, 'Pruning unused css in ${css.content.id}', () async {
        var source = await css.content.readAsString();
        var sourceFile = new SourceFile(source, url: css.content.id.toString());

        var transaction = new TextEditTransaction(source, sourceFile);
        dropUnusedCssRules(
            transform, transaction, settings, sourceFile, htmlTemplate);

        if (!transaction.hasEdits) return css;

        var printer = transaction.commit()..build(css.content.id.path);
        // TODO(ochafik): Better stats / reporting (delta + %).
        transform.logger.info("Size[${css.content.id}]: "
            "before = ${source.length}, after = ${printer.text.length}");
        return new _Css(
            original: css.content,
            content: new Asset.fromString(css.content.id, printer.text),
            map: new Asset.fromString(
                css.content.id.addExtension('.map'), printer.map));
      });

  Future<_Css> _inlineImages(_Css css, Transform transform) =>
      _time(transform, 'Inlining images in ${css.content.id}', () async {
        var result = await inlineImages(
            css.content, settings.imageInlining.value,
            assetFetcher: (String url, {AssetId from}) {
          return pathResolver.resolveAsset(transform, [url], from);
        });
        result.logMessages(transform);
        if (!result.success) return css;
        return new _Css(
            original: css.content, content: result.css, map: result.map);
      });

  @override toString() => "Scissors";
}