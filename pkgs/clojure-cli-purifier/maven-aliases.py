# SPDX-License-Identifier: MIT
"""Private Maven aliases for independent tools.deps bases in a working tree."""
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, sys.argv[1])
import coursier_inputs as coursier
import jvm_repository as jvm

repository, metadata, requested = map(Path, sys.argv[2:])
catalog = metadata / 'catalog.json'
modules = jvm.read_catalogs([{'catalog': str(catalog)}])
requests = {key: {module['originalVersion']} for key, module in modules.items()}
for line in requested.read_text().splitlines():
    group, name, version = line.split('\t')
    key = group, name
    if key in modules:
        selected = coursier.candidate(version, modules[key]['originalVersion'])
        if selected is None:
            raise ValueError('unresolved tools.deps version for ' + group + ':' + name)
        requests[key].add(selected)
# tools.build and git prep can create bases independently from the CLI.
# Their Maven descriptors still identify the requested native versions.
for path in repository.rglob('*.pom'):
    model, properties, _ = jvm.pom_model(path)
    for element in model.iter():
        if jvm.local(element) not in ('dependency', 'parent'):
            continue
        key = tuple(jvm.expand(jvm.text(element, field), properties) for field in ('groupId', 'artifactId'))
        if key in modules:
            version = jvm.expand(jvm.text(element, 'version'), properties)
            if version and '${' not in version:
                selected = coursier.candidate(version, modules[key]['originalVersion'])
                if selected is not None:
                    requests[key].add(selected)
paths = set(json.loads((metadata / 'supplied-paths.json').read_text()))
for key, module in modules.items():
    group, name = key
    actual = module['version']
    directory = repository / group.replace('.', '/') / name
    for version in requests[key]:
        if version == actual:
            continue
        jvm.validate_coordinates(group, name, version)
        for source in sorted((directory / actual).iterdir()):
            if not source.is_file() or source.suffix in coursier.CHECKSUMS:
                continue
            target = directory / version / jvm.renamed(source.name, name, actual, version)
            contents = source.read_bytes()
            if source.suffix == '.pom':
                model = ET.fromstring(contents)
                jvm.put(model, 'version', version)
                contents = ET.tostring(model, encoding='utf-8', xml_declaration=True)
            elif source.suffix == '.module':
                contents = jvm.module_metadata(source, {**module, 'originalVersion': actual, 'version': version}, modules)
            coursier.replace(target, contents)
            paths.add(target.relative_to(repository).as_posix())
    root = ET.Element('metadata')
    for field, value in (('groupId', group), ('artifactId', name)):
        ET.SubElement(root, field).text = value
    versioning = ET.SubElement(root, 'versioning')
    versions = ET.SubElement(versioning, 'versions')
    for version in sorted(path.name for path in directory.iterdir() if path.is_dir()):
        ET.SubElement(versions, 'version').text = version
    target = directory / 'maven-metadata-local.xml'
    coursier.replace(target, ET.tostring(root, encoding='utf-8', xml_declaration=True))
    paths.add(target.relative_to(repository).as_posix())
(metadata / 'supplied-paths.json').write_text(json.dumps(sorted(paths)))
