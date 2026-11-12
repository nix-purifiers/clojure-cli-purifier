# SPDX-License-Identifier: MIT
"""Export the native Clojure application basis, including local and git libs."""
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, sys.argv[1])
import coursier_runtime
import jvm_repository as jvm

basis, cache, catalog, destination, pom = map(Path, sys.argv[2:])
modules = json.loads(basis.read_text())['modules']
selected = {module['library']: module for module in modules}
local = [module for module in modules if module['version'] is None]


def coordinate(module):
    # Source libraries become owned publications. The shared projector binds
    # their native version to the producing Nix derivation automatically.
    return module['group'], module['name'], module['version'] or '0'


def dependency(parent, module):
    element = ET.SubElement(parent, 'dependency')
    for tag, value in zip(('groupId', 'artifactId', 'version'), coordinate(module)):
        ET.SubElement(element, tag).text = value


def library_jar(module, target):
    files = {}
    for entry in module['paths'] or []:
        path = Path(entry)
        if not path.exists():
            continue  # Native bases include optional resources directories.
        if path.is_dir():
            entries = ((file.relative_to(path).as_posix(), file.read_bytes())
                       for file in sorted(path.rglob('*')) if file.is_file())
        elif zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                entries = [(name, archive.read(name)) for name in sorted(archive.namelist())
                           if not name.endswith('/')]
        else:
            raise ValueError('unsupported Clojure source library classpath: '+str(path))
        for name, contents in entries:
            if name.startswith('/') or '..' in Path(name).parts:
                raise ValueError('unsafe source library entry: '+name)
            previous = files.setdefault(name, contents)
            if previous != contents:
                raise ValueError('conflicting Clojure library resource: '+name)
    if not files:
        raise ValueError('source library has no native classpath files: '+module['library'])
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, contents in sorted(files.items()):
            entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 2))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, contents)


for module in local:
    group, name, version = coordinate(module)
    jvm.validate_coordinates(group, name, version)
    directory = destination/'local-publications'/group.replace('.', '/')/name/version
    library_jar(module, directory/f'{name}-{version}.jar')
    root = ET.Element('project', {'xmlns': 'http://maven.apache.org/POM/4.0.0'})
    ET.SubElement(root, 'modelVersion').text = '4.0.0'
    for tag, value in zip(('groupId', 'artifactId', 'version'), (group, name, version)):
        ET.SubElement(root, tag).text = value
    dependencies = ET.SubElement(root, 'dependencies')
    for library in module['dependencies']:
        dependency(dependencies, selected[library])
    jvm.write(directory/f'{name}-{version}.pom', jvm.xml_bytes(root))

# tools.build deliberately omits source coordinates from the generated POM.
# Restore the actual root edges so ordinary JVM consumers receive their JARs.
root, properties, _ = jvm.pom_model(pom)
by_coordinate = {(module['group'], module['name']): module for module in modules}
dependencies = jvm.child(root, 'dependencies')
for entry in dependencies if dependencies is not None else []:
    if jvm.text(entry, 'scope') in {'test', 'provided', 'system', 'import'}:
        continue
    key = (jvm.expand(jvm.text(entry, 'groupId'), properties),
           jvm.expand(jvm.text(entry, 'artifactId'), properties))
    module = by_coordinate.get(key)
    if module is None:
        raise ValueError('published dependency is absent from the native application basis: '+str(key))
    version = jvm.expand(jvm.text(entry, 'version'), properties)
    if (module['version'] is not None and version and '${' not in version
            and version not in {module['version'], module['requested']}):
        raise ValueError('published dependency differs from the native application basis: '+str(key)
                         +': '+version+' versus '+str(module['version']))
namespace = root.tag.split('}', 1)[0]+'}' if root.tag.startswith('{') else ''
dependencies = jvm.child(root, 'dependencies')
for module in local:
    if module['root']:
        if dependencies is None:
            dependencies = ET.SubElement(root, namespace+'dependencies')
        existing = next((entry for entry in dependencies
                         if jvm.text(entry, 'groupId') == module['group']
                         and jvm.text(entry, 'artifactId') == module['name']), None)
        if existing is None:
            dependency(dependencies, module)
        else:
            jvm.put(existing, 'version', '0')
pom.write_bytes(jvm.xml_bytes(root)+b'\n')
classpath = [entry for module in modules if module['version'] is not None
             for entry in module['paths'] or [] if Path(entry).is_file()]
coursier_runtime.export(cache, classpath, catalog, destination/'runtime')
