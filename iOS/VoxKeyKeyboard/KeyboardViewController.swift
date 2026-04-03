import UIKit

class KeyboardViewController: UIInputViewController {

    enum KeyboardState {
        case idle
        case recording
        case transcribing
        case appNotRunning
    }

    private var state: KeyboardState = .idle {
        didSet { updateUI() }
    }

    private var micButton: UIButton!
    private var statusLabel: UILabel!
    private var spaceButton: UIButton!
    private var deleteButton: UIButton!
    private var returnButton: UIButton!
    private var timer: Timer?
    private var recordingSeconds: Int = 0
    private var deleteRepeatTimer: Timer?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupIPCListeners()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        checkAppAlive()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        deleteRepeatTimer?.invalidate()
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let inputView = self.inputView else { return }

        let heightConstraint = inputView.heightAnchor.constraint(equalToConstant: 220)
        heightConstraint.priority = .required
        heightConstraint.isActive = true

        // --- Top row: status label ---
        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Tap to speak"
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        inputView.addSubview(statusLabel)

        // --- Center: mic button ---
        micButton = UIButton(type: .system)
        micButton.translatesAutoresizingMaskIntoConstraints = false
        let micConfig = UIImage.SymbolConfiguration(pointSize: 36, weight: .medium)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: micConfig), for: .normal)
        micButton.tintColor = .systemBlue
        micButton.backgroundColor = .systemGray5
        micButton.layer.cornerRadius = 32
        micButton.clipsToBounds = true
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        inputView.addSubview(micButton)

        // --- Bottom toolbar: [globe] [space] [delete] [return] ---
        let toolbar = UIStackView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.axis = .horizontal
        toolbar.spacing = 6
        toolbar.alignment = .fill
        toolbar.distribution = .fill
        inputView.addSubview(toolbar)

        // Globe button (required by Apple)
        let globeBtn = makeToolbarButton(systemName: "globe", width: 40)
        globeBtn.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        toolbar.addArrangedSubview(globeBtn)

        // Space bar (flexible width)
        spaceButton = makeToolbarButton(title: "space", width: nil)
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        toolbar.addArrangedSubview(spaceButton)

        // Backspace
        deleteButton = makeToolbarButton(systemName: "delete.left", width: 50)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        // Long press for repeat delete
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(deleteLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        deleteButton.addGestureRecognizer(longPress)
        toolbar.addArrangedSubview(deleteButton)

        // Return
        returnButton = makeToolbarButton(title: "return", width: 70)
        returnButton.backgroundColor = .systemBlue
        returnButton.setTitleColor(.white, for: .normal)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        toolbar.addArrangedSubview(returnButton)

        // --- Layout ---
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: inputView.topAnchor, constant: 10),
            statusLabel.centerXAnchor.constraint(equalTo: inputView.centerXAnchor),

            micButton.centerXAnchor.constraint(equalTo: inputView.centerXAnchor),
            micButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            micButton.widthAnchor.constraint(equalToConstant: 64),
            micButton.heightAnchor.constraint(equalToConstant: 64),

            toolbar.leadingAnchor.constraint(equalTo: inputView.leadingAnchor, constant: 4),
            toolbar.trailingAnchor.constraint(equalTo: inputView.trailingAnchor, constant: -4),
            toolbar.bottomAnchor.constraint(equalTo: inputView.bottomAnchor, constant: -6),
            toolbar.heightAnchor.constraint(equalToConstant: 42),
        ])
    }

    private func makeToolbarButton(systemName: String? = nil, title: String? = nil, width: CGFloat?) -> UIButton {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false

        if let systemName {
            let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            btn.setImage(UIImage(systemName: systemName, withConfiguration: config), for: .normal)
        }
        if let title {
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 15, weight: .regular)
        }

        btn.tintColor = .label
        btn.backgroundColor = .systemGray5
        btn.layer.cornerRadius = 8
        btn.clipsToBounds = true

        if let width {
            btn.widthAnchor.constraint(equalToConstant: width).isActive = true
        }

        return btn
    }

    // MARK: - IPC

    private func setupIPCListeners() {
        IPC.observe(IPC.recordingStarted) { [weak self] in
            self?.state = .recording
            self?.startRecordingTimer()
        }

        IPC.observe(IPC.resultReady) { [weak self] in
            self?.handleResultReady()
        }

        IPC.observe(IPC.errorOccurred) { [weak self] in
            let msg = AppGroup.userDefaults.string(forKey: AppGroup.errorMessage) ?? "Error"
            self?.statusLabel.text = msg
            self?.state = .idle
        }
    }

    // MARK: - Actions

    @objc private func micTapped() {
        switch state {
        case .idle:
            guard isAppAlive() else {
                state = .appNotRunning
                return
            }
            state = .recording
            AppGroup.writeCommand("start")
            IPC.post(IPC.startRecording)

        case .recording:
            AppGroup.writeCommand("stop")
            IPC.post(IPC.stopRecording)
            state = .transcribing
            timer?.invalidate()

        case .transcribing:
            break

        case .appNotRunning:
            if isAppAlive() {
                state = .idle
            }
        }
    }

    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func deleteLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.textDocumentProxy.deleteBackward()
            }
        case .ended, .cancelled:
            deleteRepeatTimer?.invalidate()
            deleteRepeatTimer = nil
        default:
            break
        }
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
    }

    private func handleResultReady() {
        guard let text = AppGroup.readResult(), !text.isEmpty else {
            state = .idle
            return
        }

        textDocumentProxy.insertText(text)
        state = .idle
    }

    // MARK: - UI Updates

    private func updateUI() {
        DispatchQueue.main.async { [self] in
            let config = UIImage.SymbolConfiguration(pointSize: 36, weight: .medium)

            switch state {
            case .idle:
                micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
                micButton.tintColor = .systemBlue
                micButton.backgroundColor = .systemGray5
                statusLabel.text = "Tap to speak"

            case .recording:
                micButton.setImage(UIImage(systemName: "stop.fill", withConfiguration: config), for: .normal)
                micButton.tintColor = .white
                micButton.backgroundColor = .systemRed
                statusLabel.text = "Recording..."

            case .transcribing:
                micButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)
                micButton.tintColor = .systemOrange
                micButton.backgroundColor = .systemGray5
                statusLabel.text = "Transcribing..."

            case .appNotRunning:
                micButton.setImage(UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: config), for: .normal)
                micButton.tintColor = .systemYellow
                micButton.backgroundColor = .systemGray5
                statusLabel.text = "Open HushType app first"
            }
        }
    }

    // MARK: - Helpers

    private func isAppAlive() -> Bool {
        AppGroup.isAppAlive()
    }

    private func checkAppAlive() {
        if !isAppAlive() {
            state = .appNotRunning
        }
    }

    private func startRecordingTimer() {
        recordingSeconds = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingSeconds += 1
            self.statusLabel.text = "Recording... 0:\(String(format: "%02d", self.recordingSeconds))"
        }
    }

    override var needsInputModeSwitchKey: Bool { true }
}
