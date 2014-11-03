module.exports = function(context) {
  console.log('JS - after ios install - starting');

  console.log(context);

  var xcode = context.requireCordovaModule('xcode');
  var shell = context.requireCordovaModule('shelljs');
  var fs = context.requireCordovaModule('fs');
  var path = context.requireCordovaModule('path');

  console.log(context.opts.projectRoot);
  console.log(JSON.stringify(context.opts.plugin.pluginInfo));
  var projectPath = context.opts.projectRoot + '/platforms/ios/';
  var id = context.opts.plugin.pluginInfo.id;
  var project = xcode.project(projectPath);
  //console.log('project: ' + JSON.stringify(project));
  //console.log('product name: ' + project.productName());
  console.log('JS - after ios install - done');
}
