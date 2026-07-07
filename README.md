# Maven Central Audit

With the incoming enforcement of Maven Central publisher usage limits many publishers, including Telicent, are having to
figure out whether they can be more efficient in what they publish to Maven Central to reduce their usage. The script in
this repository is designed to audit Maven projects to analyse what they would release and highlight any obvious
problems.

# Requirements

- The `mvn` tool installed on your `PATH`
- The `xidel` tool installed on your `PATH` - this is used to apply XPath expressions to effective module POM files to
  help determine some release/plugin configurations
- The `jq` tool installed on your `PATH` - this is used to help prepare the JSON [audit report](#output)

# Run

From a Maven project directory simply run `audit.sh` e.g.

```bash
/path/to/mvn-central-audit/audit.sh
```

## What it does

The script runs an 8 step audit process, the outputs of each step are written to a temporary directory under
`/tmp/<hash>` where `<hash>` is the `md5` hash of the directory you are running the script against i.e. each unique
Maven project directory you run this script against has unique isolated outputs.  This means the script can be run
against many Maven project directories safely in parallel.

The 8 steps are as follows:

1. Validates that you are in a Maven project directory i.e. there is a `pom.xml` file present
2. Validates that the `pom.xml` file is configured to use the Maven Central publishing plugin
3. Quick builds the Maven project (`mvn clean install`) with various skip flags set to skip over time consuming steps.
   This step mainly serves to validate that the project is minimally buildable.
4. Determines the list of Maven modules in the project
5. Determines which of those Maven modules are actually published i.e. those that don't set the `skipPublishing`
   property/configuration for the Maven central publishing plugin to `true`
6. Does a dry-run of `mvn deploy`.  Since the Maven Central publishing plugin doesn't have a dry-run mode we achieve
   this by disabling `autoPublish` and setting a fake `centralBaseUrl` (pointing at `localhost`) so it doesn't
   accidentally create a deployment on Maven Central
7. Determines the prepared bundle directories for each published module
8. Audits each published module

Note that each step produces outputs to the aforementioned temporary directory as appropriate, therefore the script
allows you to skip checks if you make changes based on the audit report that don't require you to re-run the entire
script.  To do this supply the desired starting step as an argument to this script e.g. `audit.sh 5` restarts from the
published module detection step if you had made some changes to skip publishing certain modules.

### Audit Checks

For each published module the following audit checks are carried out:

- Counts the number of release files, and sums the total size in bytes, of the release files for the module
- If a module produces more than 4MB of release files then lists the top 5 largest files for the module
    - Checks whether the Maven Shade plugin is being used and if so issues a warning that the module may be producing a
      fat JAR.  Fat JARs should avoid being published to Maven Central unless there's a strong reason to do so.
- If a module produces a `tests` and/or `test-sources` JAR(s) checks whether the modules `tests` classifier is used as a
  dependency of other modules in the project.
    - If not used as an internal project dependency issues warnings as these JARs are unnecessary **UNLESS** they
       contain reusable test code you expect downstream consumers outside your project to reuse.
- If a module produces CycloneDX SBOMs checks whether multiple SBOM formats are being produced.
    - If so issues a warning since SBOMs will contain the same data and no need to publish multiple formats to Maven
      Central

Once these have run on all modules a summary is also printed showing the total number of release files and total release
size in bytes.

Additionally the audit script calculates how many additional hash files will need to be published with the release and
how large those would be.  If your project is configured to produce all checksum formats then a warning will be issued
suggesting that you configure the Maven Central publishing plugin to only publish `required` checksums to reduce total
number of release files.

### Output

As already noted various output files are produced to a temporary directory named `/tmp/<hash>` where `<hash>` is the
MD5 hash of the Maven project directory the script is run against.  You can manually inspect the files in this directory
if you wish to understand more about how the audit works.

However for most users the script logs human readable output about it's progress and findings which should be
sufficient, e.g., output for a local clone of our https://github.com/telicent-oss/jena-fuseki-kafka repository:

```
[Tue  7 Jul 2026 11:46:27 BST] INFO: Temporary Output Files will be written to /tmp/a89b9a8ec02b4448581d052334e8de81/

[Tue  7 Jul 2026 11:46:27 BST] INFO: Step 1: Validate Maven Project Directory
[Tue  7 Jul 2026 11:46:27 BST] INFO: Validated that current directory is a Maven project directory

[Tue  7 Jul 2026 11:46:27 BST] INFO: Step 2: Validate Maven Central Publishing Plugin used
[Tue  7 Jul 2026 11:46:29 BST] INFO: Validated that Maven project uses Maven Central publishing plugin

[Tue  7 Jul 2026 11:46:29 BST] INFO: Step 3: Quick Building the Maven Project
[Tue  7 Jul 2026 11:46:29 BST] INFO: Quick building the Maven Project (skipping tests, GPG signing, CycloneDX SBOMs, Javadoc, Source and Delombok)
[Tue  7 Jul 2026 11:46:42 BST] INFO: Maven project quick builds OK

[Tue  7 Jul 2026 11:46:42 BST] INFO: Step 4: Determining Maven Modules
[Tue  7 Jul 2026 11:46:42 BST] INFO: Detecting Maven Modules...
[Tue  7 Jul 2026 11:46:45 BST] INFO: Found 4 Maven modules in this project

[Tue  7 Jul 2026 11:46:45 BST] INFO: Step 5: Determining which Maven Modules are Published
[Tue  7 Jul 2026 11:46:45 BST] INFO: Checking whether Maven Module jena-kafka is published to Maven central...
[Tue  7 Jul 2026 11:46:48 BST] INFO: Maven Module jena-kafka is published to Maven Central
[Tue  7 Jul 2026 11:46:48 BST] INFO: Checking whether Maven Module jena-kafka-connector is published to Maven central...
[Tue  7 Jul 2026 11:46:52 BST] INFO: Maven Module jena-kafka-connector is published to Maven Central
[Tue  7 Jul 2026 11:46:52 BST] INFO: Checking whether Maven Module jena-fuseki-kafka-module is published to Maven central...
[Tue  7 Jul 2026 11:46:56 BST] INFO: Maven Module jena-fuseki-kafka-module is published to Maven Central
[Tue  7 Jul 2026 11:46:56 BST] INFO: Checking whether Maven Module jena-fmod-kafka is published to Maven central...
[Tue  7 Jul 2026 11:47:00 BST] WARN: Detected Maven Module jena-fmod-kafka skips publishing to Maven Central
[Tue  7 Jul 2026 11:47:00 BST] INFO: 3/4 modules are published to Maven Central
[Tue  7 Jul 2026 11:47:00 BST] INFO: Maven Project will generate 2 hash files per release file

[Tue  7 Jul 2026 11:47:00 BST] INFO: Step 6: Maven Deploy Dry Run
[Tue  7 Jul 2026 11:47:00 BST] INFO: Dry running mvn deploy (with tests skipped) to audit publishing bundle files...
[Tue  7 Jul 2026 11:47:27 BST] INFO: Dry ran mvn deploy

[Tue  7 Jul 2026 11:47:27 BST] INFO: Step 7: Determining Bundle directories
[Tue  7 Jul 2026 11:47:29 BST] INFO: Maven Module jena-kafka has bundle directory target/central-deferred/io/telicent/jena/jena-kafka/3.0.5-SNAPSHOT/
[Tue  7 Jul 2026 11:47:31 BST] INFO: Maven Module jena-kafka-connector has bundle directory target/central-deferred/io/telicent/jena/jena-kafka-connector/3.0.5-SNAPSHOT/
[Tue  7 Jul 2026 11:47:33 BST] INFO: Maven Module jena-fuseki-kafka-module has bundle directory target/central-deferred/io/telicent/jena/jena-fuseki-kafka-module/3.0.5-SNAPSHOT/

[Tue  7 Jul 2026 11:47:34 BST] INFO: Step 8: Auditing Maven Central bundles

[Tue  7 Jul 2026 11:47:34 BST] INFO: Auditing Maven Central bundle for Maven Module jena-kafka...
[Tue  7 Jul 2026 11:47:34 BST] INFO: Maven Module jena-kafka publishes 4 release files
[Tue  7 Jul 2026 11:47:34 BST] INFO: Maven Module jena-kafka publishes 317.53 KiB bytes of release files
[Tue  7 Jul 2026 11:47:34 BST] INFO: Preparing JSON report for module...
[Tue  7 Jul 2026 11:47:34 BST] INFO: Maven Module jena-kafka audit complete

[Tue  7 Jul 2026 11:47:34 BST] INFO: Auditing Maven Central bundle for Maven Module jena-kafka-connector...
[Tue  7 Jul 2026 11:47:34 BST] INFO: Maven Module jena-kafka-connector publishes 10 release files
[Tue  7 Jul 2026 11:47:34 BST] INFO: Maven Module jena-kafka-connector publishes 387.63 KiB bytes of release files
[Tue  7 Jul 2026 11:47:34 BST] INFO: Preparing JSON report for module...
[Tue  7 Jul 2026 11:47:34 BST] INFO: Maven Module jena-kafka-connector audit complete

[Tue  7 Jul 2026 11:47:34 BST] INFO: Auditing Maven Central bundle for Maven Module jena-fuseki-kafka-module...
[Tue  7 Jul 2026 11:47:34 BST] INFO: Maven Module jena-fuseki-kafka-module publishes 12 release files
[Tue  7 Jul 2026 11:47:34 BST] INFO: Maven Module jena-fuseki-kafka-module publishes 498.38 KiB bytes of release files
[Tue  7 Jul 2026 11:47:37 BST] WARN: Maven Module jena-fuseki-kafka-module publishes a tests classifier JAR that is not used as a dependency within this project, if this is not required by downstream consumers consider skipping test-jar packaging for this module
[Tue  7 Jul 2026 11:47:37 BST] INFO: Preparing JSON report for module...
[Tue  7 Jul 2026 11:47:37 BST] INFO: Merging warnings into JSON report
[Tue  7 Jul 2026 11:47:37 BST] INFO: Maven Module jena-fuseki-kafka-module audit complete

[Tue  7 Jul 2026 11:47:37 BST] INFO: Maven Project publishes 26 release files
[Tue  7 Jul 2026 11:47:37 BST] INFO: An additional 26 hash files will also be published
[Tue  7 Jul 2026 11:47:37 BST] INFO: Hash files will add an additional 1.82 KiB bytes of hash files

[Tue  7 Jul 2026 11:47:37 BST] INFO: Maven Project publishes 1.17 MiB bytes of release files
[Tue  7 Jul 2026 11:47:37 BST] INFO: JSON Audit Report available as /tmp/a89b9a8ec02b4448581d052334e8de81/audit-report.json

```

As seen at the end of the exampler log output it also prepares an `audit-report.json` file that contains a summary of
the audit.

The report starts with summary information:

- `totalFiles` - Total number of release files a release will generate (this does not include `hashFiles`)
- `totalSize` - Total size in bytes that a release will generate (this does not include the additional `hashFilesSize`)
- `hashFiles` - How many additional hash files will be published by a release
- `hashFilesSize` - Total size in bytes of the hash files for the release

It then goes into detailed per-module reports, each item in the `modules` array contains the following:

- `module` - The name of the module
- `files` - An array of objects each representing a single release file, the array is sorted from largest to smallest
  file:
    - `file` - Indicates the name of a release file
    - `size` - Indicates the size in bytes of the release file
- `warnings` - An optional field, if present it is an array of warning messages indicating any potential issues with the
  module that you may wish to address

Here's an example audit report:

```json
{
  "totalFiles": "26",
  "totalSize": "1232445",
  "hashFiles": "26",
  "hashFilesSize": "1872",
  "modules": [
    {
      "module": "jena-fuseki-kafka-module",
      "files": [
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT-cyclonedx.json",
          "size": "284106"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT-javadoc.jar",
          "size": "124285"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT-tests.jar",
          "size": "45270"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT.jar",
          "size": "23946"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT-sources.jar",
          "size": "18530"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT.pom",
          "size": "9212"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT-cyclonedx.json.asc",
          "size": "833"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT-javadoc.jar.asc",
          "size": "833"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT-sources.jar.asc",
          "size": "833"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT-tests.jar.asc",
          "size": "833"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT.jar.asc",
          "size": "833"
        },
        {
          "file": "jena-fuseki-kafka-module-3.0.5-SNAPSHOT.pom.asc",
          "size": "833"
        }
      ],
      "warnings": [
        "Publishes a tests classifier JAR that is not used as a dependency within this project.  If not required by downstream consumers consider skipping test-jar packaging for this module"
      ]
    },
    {
      "module": "jena-kafka-connector",
      "files": [
        {
          "file": "jena-kafka-connector-3.0.5-SNAPSHOT-javadoc.jar",
          "size": "169395"
        },
        {
          "file": "jena-kafka-connector-3.0.5-SNAPSHOT-cyclonedx.json",
          "size": "129641"
        },
        {
          "file": "jena-kafka-connector-3.0.5-SNAPSHOT.jar",
          "size": "45509"
        },
        {
          "file": "jena-kafka-connector-3.0.5-SNAPSHOT-sources.jar",
          "size": "38745"
        },
        {
          "file": "jena-kafka-connector-3.0.5-SNAPSHOT.pom",
          "size": "9483"
        },
        {
          "file": "jena-kafka-connector-3.0.5-SNAPSHOT-cyclonedx.json.asc",
          "size": "833"
        },
        {
          "file": "jena-kafka-connector-3.0.5-SNAPSHOT-javadoc.jar.asc",
          "size": "833"
        },
        {
          "file": "jena-kafka-connector-3.0.5-SNAPSHOT-sources.jar.asc",
          "size": "833"
        },
        {
          "file": "jena-kafka-connector-3.0.5-SNAPSHOT.jar.asc",
          "size": "833"
        },
        {
          "file": "jena-kafka-connector-3.0.5-SNAPSHOT.pom.asc",
          "size": "833"
        }
      ]
    },
    {
      "module": "jena-kafka",
      "files": [
        {
          "file": "jena-kafka-3.0.5-SNAPSHOT-cyclonedx.json",
          "size": "292859"
        },
        {
          "file": "jena-kafka-3.0.5-SNAPSHOT.pom",
          "size": "30635"
        },
        {
          "file": "jena-kafka-3.0.5-SNAPSHOT-cyclonedx.json.asc",
          "size": "833"
        },
        {
          "file": "jena-kafka-3.0.5-SNAPSHOT.pom.asc",
          "size": "833"
        }
      ]
    }
  ]
}
```

# License

This is open source code under the [Apache License 2.0](LICENSE), please see [NOTICE](NOTICE) for Copyright Notices.