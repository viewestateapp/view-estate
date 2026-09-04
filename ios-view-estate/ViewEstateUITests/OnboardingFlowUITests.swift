import XCTest

/// Walks account creation end to end on the simulator — welcome screen through to the
/// credits landing on Home — once for Portugal and once for Brazil, asserting the
/// terminology that must differ between the two founding markets at every step.
final class OnboardingFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Portugal

    @MainActor
    func testAccountCreationPortugal() throws {
        let app = launch(region: "PT")

        // Welcome
        let createAccount = app.buttons["welcome.createAccount"]
        XCTAssertTrue(createAccount.waitForExistence(timeout: 20), "Welcome screen never appeared")
        XCTAssertEqual(app.buttons["welcome.signIn"].label, "Entrar")
        XCTAssertEqual(createAccount.label, "Criar conta")
        createAccount.tap()

        // 1 — Profile
        XCTAssertTrue(waitForText(app, "Quem vai fotografar?"), "Profile step missing")
        assertLabel(app.buttons["profile.agent"], contains: "Agente imobiliário")
        assertLabel(app.buttons["profile.agency"], contains: "Agência imobiliária")
        assertLabel(app.buttons["profile.photographer"], contains: "Fotógrafo imobiliário")
        assertNoText(app, "Corretor de imóveis")
        app.buttons["profile.agent"].tap()

        // 2 — Monthly volume
        XCTAssertTrue(waitForText(app, "Quantos imóveis fotografa por mês?"), "Volume step missing")
        assertLabel(app.buttons["volume.upToTwenty"], contains: "Entre 6 e 20")
        app.buttons["volume.upToTwenty"].tap()

        // 3 — Goals (multiple choice)
        XCTAssertTrue(waitForText(app, "O que quer alcançar?"), "Goals step missing")
        assertLabel(app.buttons["goal.team"], contains: "equipa")
        assertNoText(app, "equipe")
        app.buttons["goal.quality"].tap()
        app.buttons["goal.staging"].tap()
        let goalsCTA = app.buttons["onboarding.cta"]
        XCTAssertTrue(goalsCTA.isEnabled, "Continue should unlock once a goal is chosen")
        goalsCTA.tap()

        // 4 — Account details
        XCTAssertTrue(waitForText(app, "Criar conta"), "Account step missing")
        XCTAssertTrue(app.staticTexts["Email"].exists, "PT should read Email")
        XCTAssertTrue(app.staticTexts["Telemóvel"].exists, "PT should read Telemóvel")
        XCTAssertTrue(app.staticTexts["Palavra-passe"].exists, "PT should read Palavra-passe")
        assertNoText(app, "Celular")
        assertNoText(app, "Senha")
        XCTAssertTrue(existsText(app, "Portugal · EUR · RGPD"), "Region row should resolve to Portugal")

        fill(app, "field.name", with: "Rita Moreira")
        fill(app, "field.email", with: "rita.moreira@imobiliaria.pt")
        fill(app, "field.phone", with: "912345678")
        fill(app, "field.company", with: "Moreira Imobiliaria")
        fill(app, "field.password", secure: true, with: "fotografia2026")

        acceptConsent(app, mentioning: "RGPD", notMentioning: "LGPD")
        submitAccount(app)

        // 5 — Email verification
        XCTAssertTrue(waitForText(app, "Confirme o seu email"), "Verification step missing")
        XCTAssertTrue(existsText(app, "rita.moreira@imobiliaria.pt"), "Verification should name the email")
        enterCode(app, "482913")
        tapCTA(app)

        // 6 — Done, with the recommended plan and its included credits
        XCTAssertTrue(waitForText(app, "Conta criada"), "Completion step missing")
        XCTAssertTrue(existsText(app, "Bem-vindo ao View Estate, Rita."), "Completion should greet by first name")
        XCTAssertTrue(existsText(app, "PLANO RECOMENDADO"))
        XCTAssertTrue(containsText(app, "Pro"), "Volume 6–20 should recommend Pro")
        XCTAssertTrue(containsText(app, "50 incluídos no plano"), "PT wording: incluídos")
        assertNoText(app, "inclusos no plano")
        XCTAssertTrue(containsText(app, "€"), "Portugal must price in euro")
        assertNoText(app, "R$")
        XCTAssertTrue(containsText(app, "subscrição"), "PT wording: subscrição")
        tapCTA(app)

        // Credits land on Home: 50 from the plan + 10 already purchased
        let credits = app.buttons["home.credits"]
        XCTAssertTrue(credits.waitForExistence(timeout: 20), "Home never appeared after onboarding")
        assertLabel(credits, contains: "60")
        assertLabel(credits, contains: "Créditos IA")
        XCTAssertTrue(containsText(app, "Rita"), "Home should greet the new user")
    }

    // MARK: - Brazil

    @MainActor
    func testAccountCreationBrazil() throws {
        let app = launch(region: "BR")

        let createAccount = app.buttons["welcome.createAccount"]
        XCTAssertTrue(createAccount.waitForExistence(timeout: 20), "Welcome screen never appeared")
        createAccount.tap()

        // 1 — Profile
        XCTAssertTrue(waitForText(app, "Quem vai fotografar?"), "Profile step missing")
        assertLabel(app.buttons["profile.agent"], contains: "Corretor de imóveis")
        assertLabel(app.buttons["profile.agency"], contains: "Imobiliária")
        assertNoText(app, "Agente imobiliário")
        assertNoText(app, "Agência imobiliária")
        app.buttons["profile.agency"].tap()

        // 2 — Monthly volume
        XCTAssertTrue(waitForText(app, "Quantos imóveis você fotografa por mês?"), "Volume step missing")
        app.buttons["volume.upToTwenty"].tap()

        // 3 — Goals
        XCTAssertTrue(waitForText(app, "O que você quer alcançar?"), "Goals step missing")
        assertLabel(app.buttons["goal.team"], contains: "equipe")
        assertLabel(app.buttons["goal.staging"], contains: "Mobiliar")
        assertNoText(app, "equipa")
        app.buttons["goal.speed"].tap()
        app.buttons["goal.team"].tap()
        tapCTA(app)

        // 4 — Account details
        XCTAssertTrue(waitForText(app, "Criar conta"), "Account step missing")
        XCTAssertTrue(app.staticTexts["E-mail"].exists, "BR should read E-mail")
        XCTAssertTrue(app.staticTexts["Celular"].exists, "BR should read Celular")
        XCTAssertTrue(app.staticTexts["Senha"].exists, "BR should read Senha")
        assertNoText(app, "Telemóvel")
        assertNoText(app, "Palavra-passe")
        XCTAssertTrue(existsText(app, "Brasil · BRL · LGPD"), "Region row should resolve to Brazil")

        fill(app, "field.name", with: "Bruno Carvalho")
        fill(app, "field.email", with: "bruno@carvalhoimoveis.com.br")
        fill(app, "field.phone", with: "11987654321")
        fill(app, "field.company", with: "Carvalho Imoveis")
        fill(app, "field.password", secure: true, with: "fotografia2026")

        acceptConsent(app, mentioning: "LGPD", notMentioning: "RGPD")
        submitAccount(app)

        // 5 — Email verification, including resend feedback
        XCTAssertTrue(waitForText(app, "Confirme seu e-mail"), "Verification step missing")
        app.buttons["onboarding.resend"].tap()
        XCTAssertTrue(waitForText(app, "Código reenviado."), "Resend feedback missing")
        enterCode(app, "204871")
        tapCTA(app)

        // 6 — Done: an agency profile must be recommended the agency plan
        XCTAssertTrue(waitForText(app, "Conta criada"), "Completion step missing")
        XCTAssertTrue(existsText(app, "Bem-vindo ao View Estate, Bruno."))
        XCTAssertTrue(containsText(app, "200 inclusos no plano"), "BR wording: inclusos")
        assertNoText(app, "incluídos no plano")
        XCTAssertTrue(containsText(app, "R$"), "Brazil must price in real")
        assertNoText(app, "€")
        XCTAssertTrue(containsText(app, "assinatura"), "BR wording: assinatura")
        tapCTA(app)

        // Credits land on Home: 200 from the plan + 10 already purchased
        let credits = app.buttons["home.credits"]
        XCTAssertTrue(credits.waitForExistence(timeout: 20), "Home never appeared after onboarding")
        assertLabel(credits, contains: "210")
    }

    // MARK: - Harness

    @MainActor
    private func launch(region: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["VE_REGION_OVERRIDE"] = region
        app.launch()
        return app
    }

    @MainActor
    private func tapCTA(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let cta = app.buttons["onboarding.cta"]
        guard cta.waitForExistence(timeout: 10) else {
            XCTFail("Primary action missing", file: file, line: line)
            return
        }
        scrollIntoView(app, cta)
        cta.tap()
    }

    @MainActor
    private func fill(
        _ app: XCUIApplication,
        _ identifier: String,
        secure: Bool = false,
        with value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let field = secure ? app.secureTextFields[identifier] : app.textFields[identifier]
        guard field.waitForExistence(timeout: 10) else {
            XCTFail("Field \(identifier) not found", file: file, line: line)
            return
        }
        dismissKeyboard(app)
        scrollIntoView(app, field)
        guard field.isHittable else {
            XCTFail("Field \(identifier) could not be reached", file: file, line: line)
            return
        }
        field.tap()
        field.typeText(value)

        // Confirm the text really landed in this field before moving on.
        let typed = fieldValue(app, identifier, secure: secure)
        if secure {
            XCTAssertFalse(typed.isEmpty, "\(identifier) stayed empty", file: file, line: line)
        } else {
            XCTAssertEqual(typed, value, "\(identifier) holds unexpected text", file: file, line: line)
        }
    }

    @MainActor
    private func fieldValue(_ app: XCUIApplication, _ identifier: String, secure: Bool = false) -> String {
        let field = secure ? app.secureTextFields[identifier] : app.textFields[identifier]
        guard field.exists else { return "<missing>" }
        return (field.value as? String) ?? ""
    }

    @MainActor
    private func acceptConsent(
        _ app: XCUIApplication,
        mentioning expected: String,
        notMentioning unexpected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let consent = app.buttons["onboarding.consent"]
        guard consent.waitForExistence(timeout: 10) else {
            XCTFail("Consent row missing", file: file, line: line)
            return
        }
        dismissKeyboard(app)
        scrollIntoView(app, consent)
        assertLabel(consent, contains: expected, file: file, line: line)
        assertLabel(consent, doesNotContain: unexpected, file: file, line: line)
        consent.tap()
        XCTAssertTrue(consent.isSelected, "Consent did not register", file: file, line: line)
    }

    /// Submits the account form, reporting the whole form state if the action stayed locked.
    @MainActor
    private func submitAccount(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let cta = app.buttons["onboarding.cta"]
        guard cta.waitForExistence(timeout: 10) else {
            XCTFail("Account action missing", file: file, line: line)
            return
        }
        dismissKeyboard(app)
        scrollIntoView(app, cta)

        guard cta.isEnabled else {
            let state = "name=" + fieldValue(app, "field.name")
                + " email=" + fieldValue(app, "field.email")
                + " phone=" + fieldValue(app, "field.phone")
                + " company=" + fieldValue(app, "field.company")
                + " password=" + fieldValue(app, "field.password", secure: true)
                + " consent=" + String(app.buttons["onboarding.consent"].isSelected)
            XCTFail("Create account stayed locked — " + state, file: file, line: line)
            return
        }
        cta.tap()
    }

    @MainActor
    private func enterCode(_ app: XCUIApplication, _ code: String) {
        let field = app.textFields["onboarding.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Verification field not found")
        if !app.keyboards.element.waitForExistence(timeout: 3) {
            field.tap()
        }
        app.typeText(code)
    }

    /// A field hidden behind the keyboard is not tappable, so the keyboard is put away
    /// before reaching for the next one. Scrolling the form dismisses it immediately.
    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.element.exists else { return }
        app.scrollViews.firstMatch.swipeDown()
        _ = app.keyboards.element.waitForNonExistence(timeout: 3)
    }

    @MainActor
    private func scrollIntoView(_ app: XCUIApplication, _ element: XCUIElement, attempts: Int = 8) {
        var remaining = attempts
        while !element.isHittable, remaining > 0 {
            app.scrollViews.firstMatch.swipeUp()
            remaining -= 1
        }
    }

    // MARK: - Text assertions

    @MainActor
    private func waitForText(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10) -> Bool {
        app.staticTexts[text].waitForExistence(timeout: timeout) || containsText(app, text)
    }

    @MainActor
    private func existsText(_ app: XCUIApplication, _ text: String) -> Bool {
        app.staticTexts[text].exists || containsText(app, text)
    }

    /// Substring search across the visible text of the screen.
    @MainActor
    private func containsText(_ app: XCUIApplication, _ text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return app.staticTexts.matching(predicate).count > 0
            || app.buttons.matching(predicate).count > 0
    }

    @MainActor
    private func assertNoText(
        _ app: XCUIApplication,
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            containsText(app, text),
            "\"\(text)\" belongs to the other market and must not appear here",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertLabel(
        _ element: XCUIElement,
        contains text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard element.waitForExistence(timeout: 10) else {
            XCTFail("Element \(element.identifier) not found", file: file, line: line)
            return
        }
        XCTAssertTrue(
            element.label.contains(text),
            "Expected \"\(text)\" in \"\(element.label)\"",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertLabel(
        _ element: XCUIElement,
        doesNotContain text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            element.label.contains(text),
            "Did not expect \"\(text)\" in \"\(element.label)\"",
            file: file,
            line: line
        )
    }
}
