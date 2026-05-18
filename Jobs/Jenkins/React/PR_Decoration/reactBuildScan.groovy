def call(Map cfg) {

  def epic                 = cfg.epic
  def branchName           = cfg.branch.toString()
  def lob                  = (cfg.lob ?: "").toString().toUpperCase()
  def buildAgent           = cfg.buildAgent
  def sonarAgent           = cfg.sonarAgent
  def secretScanningAgent  = cfg.secretScanningAgent

  if (!branchName) {
    error("Branch name must be provided")
  }

  if (!['DXP','CXP'].contains(lob)) {
    error("Invalid LOB '${lob}'. Allowed: [DXP, CXP]")
  }

  /*
   * =========================================================
   * PR ANALYSIS CONFIG
   * =========================================================
   */

  boolean isPrAnalysis = cfg.sonar.isPrAnalysis ?: false

  String prKey    = cfg.sonar.prKey ?: ''
  String prBranch = cfg.sonar.prBranch ?: ''
  String prBase   = cfg.sonar.prBase ?: 'DEV'

  /*
   * =========================================================
   * TARGET CHECKOUT BRANCH
   * =========================================================
   */

  String targetBranch = isPrAnalysis ? prBranch : branchName

  echo """
  =========================================================
  SonarQube Analysis Mode
  ---------------------------------------------------------
  PR Analysis : ${isPrAnalysis}
  Checkout Ref: ${targetBranch}
  PR Key      : ${prKey}
  PR Branch   : ${prBranch}
  PR Base     : ${prBase}
  =========================================================
  """

  /*
   * =========================================================
   * SECRET SCAN NODE
   * =========================================================
   */

  node(secretScanningAgent) {

    stage("Checkout for Secret Scan (${targetBranch})") {

      deleteDir()

      bbs_checkout(
        branches: [[name: "*/${targetBranch}"]],
        credentialsId: cfg.bbs.credentialsId,
        id: cfg.bbs.id,
        projectName: cfg.bbs.projectName,
        repositoryName: cfg.bbs.repositoryName,
        serverId: cfg.bbs.serverId
      )
    }

    /*
    stage('Secret Scan - Gitleaks') {

      int result = bat(
        returnStatus: true,
        script: """
          E:\\gitleaks\\gitleaks.exe detect ^
          --no-git ^
          --source . ^
          --report-format json ^
          --report-path gitleaks-report.json ^
          --exit-code 1
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

  /*
   * =========================================================
   * BUILD NODE
   * =========================================================
   */

  node(buildAgent) {

    stage("Checkout for Build (${targetBranch})") {

      deleteDir()

      bbs_checkout(
        branches: [[name: "*/${targetBranch}"]],
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

      currentBuild.displayName = "${epic} ⇔ ${env.ARTIFACT_VERSION}"

      currentBuild.description =
        "Artifact: ${env.ARTIFACT_VERSION} | " +
        "Branch: ${targetBranch} | " +
        "LOB: ${lob} | " +
        "Build: #${env.BUILD_NUMBER}"
    }

    stage('Install Dependencies + Build + Test') {

      def nodeHome = tool 'NodeJS'

      env.NODE_HOME = nodeHome

      env.PATH =
        "${nodeHome};" +
        "${nodeHome}\\node_modules\\npm\\bin;" +
        "${env.PATH}"

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

      junit allowEmptyResults: true,
            testResults: 'reports/junit.xml'

      stash(
        name: 'coverage-report',
        includes: "${cfg.sonar.lcovReportPath},reports/junit.xml",
        allowEmpty: true
      )
    }
  }

  /*
   * =========================================================
   * SONAR NODE
   * =========================================================
   */

  node(sonarAgent) {

    stage("Checkout for Sonar (${targetBranch})") {

      deleteDir()

      bbs_checkout(
        branches: [[name: "*/${targetBranch}"]],
        credentialsId: cfg.bbs.credentialsId,
        id: cfg.bbs.id,
        projectName: cfg.bbs.projectName,
        repositoryName: cfg.bbs.repositoryName,
        serverId: cfg.bbs.serverId
      )

      unstash 'coverage-report'
    }

    stage('SonarQube Analysis') {

      def nodeHome    = tool 'NodeJS'
      def scannerHome = tool 'sonar-scanner-cli'

      env.NODE_HOME = nodeHome

      env.PATH =
        "${nodeHome};" +
        "${nodeHome}\\node_modules\\npm\\bin;" +
        "${scannerHome}\\bin;" +
        "${env.PATH}"

      String sonarKey = "${lob}-${cfg.sonar.projectKey}"

      String analysisModeArgs = ""

      if (isPrAnalysis) {

        echo """
        Running SonarQube PR Analysis:
        PR Key    : ${prKey}
        Source    : ${prBranch}
        Target    : ${prBase}
        """

        analysisModeArgs =
          "-Dsonar.pullrequest.key=${prKey} " +
          "-Dsonar.pullrequest.branch=${prBranch} " +
          "-Dsonar.pullrequest.base=${prBase}"

      } else {

        echo "Running SonarQube Branch Analysis: ${targetBranch}"

        analysisModeArgs =
          "-Dsonar.branch.name=${targetBranch}"
      }

      withSonarQubeEnv(cfg.sonar.server) {

        bat """
          "${scannerHome}\\bin\\sonar-scanner.bat" ^
          -Dsonar.projectKey=${sonarKey} ^
          -Dsonar.projectName=${sonarKey} ^
          -Dsonar.projectVersion=${env.ARTIFACT_VERSION} ^
          -Dsonar.sources=${cfg.sonar.sources} ^
          -Dsonar.inclusions=${cfg.sonar.inclusions} ^
          -Dsonar.typescript.tsconfigPaths=${cfg.sonar.tsconfigPaths} ^
          -Dsonar.javascript.lcov.reportPaths=${cfg.sonar.lcovReportPath} ^
          -Dsonar.sourceEncoding=UTF-8 ^
          ${analysisModeArgs} ^
          -Dsonar.exclusions=${cfg.sonar.exclusions} ^
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

    stage('Fail Build If Unit Tests Failed') {

      junit 'reports/junit.xml'
    }
  }

  /*
   * =========================================================
   * ARCHIVE
   * =========================================================
   */

  node(buildAgent) {

    stage('Archive Artifacts') {

      bat 'echo %EPIC% > epic.txt'

      writeFile(
        file: 'artifact_version.txt',
        text: env.ARTIFACT_VERSION
      )

      archiveArtifacts(
        artifacts: "${cfg.artifacts.path},artifact_version.txt,epic.txt",
        fingerprint: true,
        onlyIfSuccessful: true
      )
    }
  }
}