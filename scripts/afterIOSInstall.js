module.exports = function(context) {
  console.log('JS - after ios install - starting');

  var xcode = context.requireCordovaModule('xcode');
  var shell = context.requireCordovaModule('shelljs');
  var fs = context.requireCordovaModule('fs');
  var path = context.requireCordovaModule('path');

  var projectPath = context.opts.projectRoot + '/platforms/ios/';
  var id = context.opts.plugin.pluginInfo.id;
  var project = xcode.project(projectPath);

  if (process.env.VLC_FRAMEWORK_LOCATION===undefined) { throw new Error('environment variable VLC_FRAMEWORK_LOCATION not found'); }
  var srcFile = process.env.VLC_FRAMEWORK_LOCATION;
  // how to determine this path dynamically?
  var frameworkFolder = srcFile.substring(srcFile.lastIndexOf('/')+1);
  var targetDir = projectPath + '/HookTest/Plugins/' + id + '/' + frameworkFolder;
  
  if (!fs.existsSync(srcFile)) throw new Error('cannot find "' + srcFile + '" ios <framework>');
  if (fs.existsSync(targetDir)) throw new Error('target destination "' + targetDir + '" already exists');

  shell.mkdir('-p', path.dirname(targetDir));
  shell.cp('-R', srcFile, path.dirname(targetDir)); // frameworks are directories

  // parsing is async, in a different process
  project.parse(function (err) {
    var projectRelative = path.relative(projectPath, targetDir);
    //project.addFramework(projectRelative, {customFramework: true});
    //fs.writeFileSync(projectPath, project.writeSync());
  });
  console.log('JS - after ios install - done');
}
