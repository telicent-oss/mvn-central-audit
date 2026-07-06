# Maven Central Audit

With the incoming enforcement of Maven Central publisher usage limits many publishers, including my employers, are
having to figure out whether they can be more efficient in what they publish to Maven Central to reduce their usage. The
script in this repository is designed to audit Maven projects to analyse what they would release and highlight any
obvious problems.

# Requirements

- The `mvn` tool installed on your `PATH`
- The `xidel` tool installed on your `PATH` - this is used to apply XPath expressions to effective module POM files to
  help determine some release/plugin configurations

# Run

From a Maven project directory simply run `audit.sh`

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
   this by disabling `autoPublish` and setting a fake `centralBaseUrl` so it doesn't accidentally create a deployment on
   Maven Central
7. Determines the prepared bundle directories for each published module
8. Audits each published module

Note that each step produces outputs to the aforementioned temporary directory as appropriate, therefore the script
allows you to skip checks if you make changes based on the audit report that don't require you to re-run the entire
script.  To do this supply the desired starting step as an argument to this script e.g. `audit.sh 5` restarts from the
published module detection step.

### Audit Checks

For each published module the following audit checks are carried out:

- Counts the number of files, and sums the total size in bytes, of the release files for the module
- If a module produces more than 4MB of release files then lists the top 5 largest files for the module
    - Checks whether the Maven Shade plugin is being used and if so issues a warning that the module may be producing a
      fat JAR.  Far JARs should avoid being published to Maven Central unless there's a strong reason to do so.
- If a module produces a `tests` and/or `test-sources` JAR(s) checks whether the modules `tests` classifier is used as a
  dependency of other modules in the project.
    - If not used as an internal project dependency issues warnings as these JARs are unnecessary unless they contain
       reusable test code you expect downstream consumers outside your project to reuse.
- If a module produces CycloneDX SBOMs checks whether multiple SBOM formats are being produced.
    - If so issues a warning since SBOMs will contain the same data and no need to publish multiple formats to Maven
      Central

Once these have run on all modules a summary is also printed showing the total number of release files and total release
size in bytes.

Additionally the audit script calculates how many additional hash files will need to be published with the release and
how large those would be.  If your project is configured to produce all checksum formats then a warning will be issued
suggesting that you configure the Maven Central publishing plugin to only publish `required` checksums to reduce total
number of release files.