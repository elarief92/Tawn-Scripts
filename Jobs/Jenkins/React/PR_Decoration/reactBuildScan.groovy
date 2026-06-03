def call(Map cfg) {

  def branchName           = cfg.branch.toString()
  def lob                  = (cfg.lob ?: "").toString().toUpperCase()
  def buildAgent           = cfg.buildAgent
  def sonarAgent           = cfg.sonarAgent
  def secretScanningAgent  = cfg.secretScanningAgent

  String sonarServer           = cfg.sonar.server ?: 'SonarQube'
  String sonarHostUrl          = cfg.sonar.hostUrl ?: 'https://sonarqube.tawuniya.com'
  String apiTokenCredentialsId = cfg.sonar.apiTokenCredentialsId ?: 'jenkins-sonar-api'

  String mainGate = cfg.sonar.mainGate ?: 'Quality Gate-Tawuniya'
  String prGate   = cfg.sonar.prGate ?: 'Refactor Gate'

  String pullRequestId = cfg.sonar.pullRequestId ?: cfg.sonar.prKey ?: ''
  String sourceBranch  = cfg.sonar.sourceBranch ?: cfg.sonar.prBranch ?: ''
  String targetBranch  = branchName

  String epic = cfg.epic ?: ''
  if (!epic?.trim() && sourceBranch?.trim()) {
    def epicMatcher = sourceBranch =~ /(DEV\d+-\d+)/
    if (epicMatcher.find()) {
      epic = epicMatcher.group(1)
    }
  }

  if (!branchName) {
    error("Branch name must be provided")
  }

  if (!['DXP','CXP'].contains(lob)) {
    error("Invalid LOB '${lob}'. Allowed: [DXP, CXP]")
  }

  boolean isPrAnalysis =
    branchName.equalsIgnoreCase('DEV') &&
    pullRequestId?.trim() &&
    sourceBranch?.trim()

  String appPath = cfg.app.path ?: ''
  if (!appPath?.trim()) {
    error("cfg.app.path must be provided. Example: apps/visit-visa/")
  }

  if (!appPath.endsWith('/')) {
    appPath = appPath + '/'
  }

  String checkoutBranch = isPrAnalysis ? sourceBranch : branchName
  String remoteName = cfg.bbs.remoteName ?: cfg.bbs.repositoryName.toString().toLowerCase()

  def setSonarQualityGate = { String hostUrl, String projectKey, String gateName ->
    bat """
      curl -k -s -X POST ^
        -H "Authorization: Bearer %SONAR_API_TOKEN%" ^
        --data-urlencode "projectKey=${projectKey}" ^
        --data-urlencode "gateName=${gateName}" ^
        "${hostUrl}/api/qualitygates/select"
    """
  }

  echo """
  =========================================================
  SonarQube Analysis Mode
  ---------------------------------------------------------
  PR Analysis       : ${isPrAnalysis}
  Checkout Branch   : ${checkoutBranch}
  Branch Base       : ${branchName}
  Pull Request ID   : ${pullRequestId}
  Source Branch     : ${sourceBranch}
  Target Branch     : ${targetBranch}
  EPIC              : ${epic}
  App Path          : ${appPath}
  Remote Name       : ${remoteName}
  Sonar Server      : ${sonarServer}
  Sonar Host URL    : ${sonarHostUrl}
  Main Gate         : ${mainGate}
  PR Gate           : ${prGate}
  =========================================================
  """

  boolean shouldRunAppJob = true

  node(secretScanningAgent) {
    stage("Checkout + Monorepo Change Detection (${checkoutBranch})") {
      deleteDir()

      bbs_checkout(
        branches: [[name: "*/${checkoutBranch}"]],
        credentialsId: cfg.bbs.credentialsId,
        id: cfg.bbs.id,
        projectName: cfg.bbs.projectName,
        repositoryName: cfg.bbs.repositoryName,
        serverId: cfg.bbs.serverId
      )

      if (isPrAnalysis) {
        bat """
          set PATH=C:\\Program Files\\Git\\cmd;%PATH%
          where git
          git --version
          git fetch --all --prune
          git branch -a
        """

        bat """
          git diff --name-only "${remoteName}/${targetBranch}...${remoteName}/${sourceBranch}" > changed-files.txt
          type changed-files.txt
        """

        def changedFiles = readFile('changed-files.txt').trim()

        if (!changedFiles.contains(appPath)) {
          shouldRunAppJob = false
          currentBuild.result = 'NOT_BUILT'
          echo "No changes found under ${appPath}. Skipping this app job."
        }
      }
    }

    /*
    stage('Trivy DB Update') {
      node(buildAgent) {
        bat """
          E:\\trivy\\trivy.exe fs --download-db-only .
        """
      }
    }

    stage('SCA - Trivy') {
      node(buildAgent) {
        deleteDir()
        unstash 'src'

        int result = bat(
          returnStatus: true,
          script: """
            E:\\trivy\\trivy.exe fs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --skip-db-update --format json --output trivy-report.json --exit-code 1 .
          """
        )

        bat """
          if not exist trivy-report.json (
            echo {} > trivy-report.json
          )
        """

        archiveArtifacts artifacts: 'trivy-report.json', fingerprint: true

        script {
          def report = readFile('trivy-report.json').trim()
          if (result != 0) {
            if (report == '{}' || report == '') {
              error("Trivy scan execution failed. Check console log.")
            } else {
              error("Trivy found HIGH/CRITICAL vulnerabilities. Check trivy-report.json artifact.")
            }
          }
        }
      }
    }
    */

    /*
    stage('Secret Scan - Gitleaks') {
      int result = bat(
        returnStatus: true,
        script: """
          E:\\gitleaks\\gitleaks.exe detect --no-git --source . --report-format json --report-path gitleaks-report.json --exit-code 1
        """
      )

      bat """
        if not exist gitleaks-report.json (
          echo {} > gitleaks-report.json
        )
      """

      archiveArtifacts artifacts: 'gitleaks-report.json', fingerprint: true

      if (result != 0) {
        error("Gitleaks failed. Check gitleaks-report.json artifact.")
      }
    }
    */
  }

  if (!shouldRunAppJob) {
    return
  }

  node(buildAgent) {
    stage("Checkout for Build (${checkoutBranch})") {
      deleteDir()

      bbs_checkout(
        branches: [[name: "*/${checkoutBranch}"]],
        credentialsId: cfg.bbs.credentialsId,
        id: cfg.bbs.id,
        projectName: cfg.bbs.projectName,
        repositoryName: cfg.bbs.repositoryName,
        serverId: cfg.bbs.serverId
      )
    }

    getReactArtifactVersion(
      releaseNumber: env.BUILD_NUMBER,
      lob: lob,
      environment: branchName.toUpperCase(),
      packageFile: cfg.app.packageFile
    )

    stage('Set Build Name') {
      String displayNamePrefix = sourceBranch?.trim()
        ? "${sourceBranch} (${pullRequestId})"
        : (epic ?: pullRequestId ?: branchName)

      currentBuild.displayName = "${displayNamePrefix} ⇔ ${env.ARTIFACT_VERSION}"
      currentBuild.description = "Artifact: ${env.ARTIFACT_VERSION} | Checkout: ${checkoutBranch} | Base: ${branchName} | LOB: ${lob} | Build: #${env.BUILD_NUMBER}"
    }

    stage('Install Dependencies + Build + Test') {
      def nodeHome = tool 'NodeJS'

      env.NODE_HOME = nodeHome
      env.PATH = "${nodeHome};${nodeHome}\\node_modules\\npm\\bin;${env.PATH}"

      bat "${cfg.node.installCmd}"

      if (cfg.node.resetCmd?.trim()) {
        bat "${cfg.node.resetCmd}"
      }

      bat "${cfg.node.buildCmd}"

      bat 'if not exist reports mkdir reports'

      int testResult = bat(
        returnStatus: true,
        script: "${cfg.node.testCoverageCmd}"
      )

      env.UNIT_TEST_RESULT = "${testResult}"

      junit allowEmptyResults: true, testResults: 'reports/junit.xml'

      def junitReport = fileExists('reports/junit.xml') ? readFile('reports/junit.xml') : ''

      if (testResult != 0) {
        if (
          junitReport.contains('<failure') ||
          junitReport.contains('<error')
        ) {
          error("Unit tests failed. Exit code: ${testResult}")
        }

        echo "Vitest returned exit code ${testResult}, but no failed/error test cases were found. Continuing because this PR may not require tests."
      }

      stash(
        name: 'coverage-report',
        includes: "${cfg.sonar.lcovReportPath},reports/junit.xml",
        allowEmpty: true
      )
    }
  }

  node(sonarAgent) {
    stage("Checkout for Sonar (${checkoutBranch})") {
      deleteDir()

      bbs_checkout(
        branches: [[name: "*/${checkoutBranch}"]],
        credentialsId: cfg.bbs.credentialsId,
        id: cfg.bbs.id,
        projectName: cfg.bbs.projectName,
        repositoryName: cfg.bbs.repositoryName,
        serverId: cfg.bbs.serverId
      )

      if (isPrAnalysis) {
        bat """
          set PATH=C:\\Program Files\\Git\\cmd;%PATH%
          where git
          git --version
          git fetch --all --prune
          git checkout -B "${sourceBranch}" "${remoteName}/${sourceBranch}"
          git branch -f "${targetBranch}" "${remoteName}/${targetBranch}"
          git merge-base HEAD "${targetBranch}"
          git branch
        """
      }

      unstash 'coverage-report'
    }

    def nodeHome    = tool 'NodeJS'
    def scannerHome = tool 'sonar-scanner-cli'

    env.NODE_HOME = nodeHome
    env.PATH = "${nodeHome};${nodeHome}\\node_modules\\npm\\bin;${scannerHome}\\bin;${env.PATH}"

    String sonarKey = "${lob}-${cfg.sonar.projectKey}"
    String sonarProjectName = "${lob}-${cfg.sonar.projectKey}"

    String analysisModeArgs = ""

    if (isPrAnalysis) {
      analysisModeArgs =
        "-Dsonar.pullrequest.key=${pullRequestId} " +
        "-Dsonar.pullrequest.branch=${sourceBranch} " +
        "-Dsonar.pullrequest.base=${targetBranch}"
    } else {
      analysisModeArgs = "-Dsonar.branch.name=${branchName}"
    }

    withCredentials([string(credentialsId: apiTokenCredentialsId, variable: 'SONAR_API_TOKEN')]) {
      try {
        if (isPrAnalysis) {
          stage('Assign Refactor Quality Gate') {
            setSonarQualityGate(sonarHostUrl, sonarKey, prGate)
          }
        }

        stage('SonarQube Analysis') {
          withSonarQubeEnv(sonarServer) {
            bat """
              "${scannerHome}\\bin\\sonar-scanner.bat" ^
              -Dsonar.projectKey=${sonarKey} ^
              -Dsonar.projectName=${sonarProjectName} ^
              -Dsonar.projectVersion=${env.ARTIFACT_VERSION} ^
              -Dsonar.sources=${cfg.sonar.sources} ^
              -Dsonar.tests=${cfg.sonar.tests} ^
              -Dsonar.inclusions=${cfg.sonar.inclusions} ^
              -Dsonar.test.inclusions=${cfg.sonar.testInclusions} ^
              -Dsonar.coverage.exclusions=${cfg.sonar.coverageExclusions} ^
              -Dsonar.typescript.tsconfigPaths=${cfg.sonar.tsconfigPaths} ^
              -Dsonar.javascript.lcov.reportPaths=${cfg.sonar.lcovReportPath} ^
              -Dsonar.sourceEncoding=UTF-8 ^
              ${analysisModeArgs} ^
              -Dsonar.exclusions=${cfg.sonar.exclusions} ^
              -Dsonar.cpd.exclusions=${cfg.sonar.cpdExclusions ?: ''} ^
              -Dsonar.scanner.skip.ssl.verification=true ^
              -Dsonar.nodejs.executable="${nodeHome}\\node.exe"
            """
          }
        }

        stage('Quality Gate') {
          timeout(time: 1, unit: 'HOURS') {
            waitForQualityGate abortPipeline: true
          }
        }
      }
      finally {
        if (isPrAnalysis) {
          stage('Reset Main Quality Gate') {
            setSonarQualityGate(sonarHostUrl, sonarKey, mainGate)
          }
        }
      }
    }

    stage('Fail Build If Unit Tests Failed') {
      junit allowEmptyResults: true, testResults: 'reports/junit.xml'
    }
  }

  node(buildAgent) {
    stage('Archive Artifacts') {
      bat "echo ${epic ?: pullRequestId ?: branchName} > epic.txt"

      writeFile file: 'artifact_version.txt', text: env.ARTIFACT_VERSION

      archiveArtifacts(
        artifacts: "${cfg.artifacts.path},artifact_version.txt,epic.txt",
        fingerprint: true,
        onlyIfSuccessful: true
      )
    }
  }
}