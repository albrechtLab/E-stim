function StimValidationGUI()
% StimValidationGUI  — Electrical stimulation waveform validation tool
%
% DataLogger memory-mode output format (3 columns per line):
%   time_us, V_raw, I_raw
%
% StimJim S command format:
%   S<n>,<mode0>,<mode1>,<period_us>,<duration_us>; <a0>,<a1>,<dur>; ...
%   T<n>  — trigger pattern n       T-1  — force stop
%
% Calibration:  physical = (raw - offset) / scale
%   Voltage : offset=1952, scale=41   [V]
%   Current : offset=2052, scale=843  [mA]

    %% ----------------------------------------------------------------
    %  Constants
    %% ----------------------------------------------------------------
    STIM_DURATION_US   = 2000000;  % override pulse-train duration (us) — 2 s ensures the 100 ms logger capture window always falls within the pulse
    TOTAL_TIME_PER_PAT = 1.0;      % seconds between triggers
    LOGGER_INIT_PAUSE  = 3.0;      % s between logger init commands
    SERIAL_BAUD        = 115200;
    ESTIM_FOLDER       = 'D:/Data/E_stim_waveforms';
    SJ_ACK_PAUSE       = 2.0;      % s to wait for StimJim ack after send

    %% ----------------------------------------------------------------
    %  Shared state
    %% ----------------------------------------------------------------
    settingsFile = '';
    patterns     = struct([]);
    resultData   = struct([]);
    loggerReady  = false;
    sjPort       = [];
    dlPort       = [];
    saveTimestamp = '';

    %% ----------------------------------------------------------------
    %  Build GUI  — all Layout assignments are post-construction
    %% ----------------------------------------------------------------
    fig = uifigure('Name','StimJim Waveform Validator','Position',[60 60 1300 780]);
    fig.CloseRequestFcn = @onClose;

    %  Top-level: left control panel | right results panel
    gl = uigridlayout(fig,[1 2]);
    gl.ColumnWidth = {'1x','2.4x'};
    gl.Padding     = [6 6 6 6];
    gl.ColumnSpacing = 6;

    %% --- LEFT PANEL ---------------------------------------------------
    leftPanel = uipanel(gl,'Title','Control','FontWeight','bold');
    leftPanel.Layout.Row    = 1;
    leftPanel.Layout.Column = 1;

    % 12 rows: file, filepath, SJ port, DL port, refresh, load, status,
    %          calib header, calib entry, start, saves, serial monitors
    lg = uigridlayout(leftPanel,[12 2]);
    lg.RowHeight   = {28,24,28,28,28,28,20,18,28,32,28,'1x'};
    lg.ColumnWidth = {'1x','1x'};
    lg.Padding     = [4 4 4 4];
    lg.RowSpacing  = 3;

    % Row 1 — file browse
    lblSettings = uilabel(lg,'Text','Settings file:','FontWeight','bold');
    lblSettings.Layout.Row    = 1;
    lblSettings.Layout.Column = 1;
    btnFile = uibutton(lg,'Text','Browse...','ButtonPushedFcn',@browseFile);
    btnFile.Layout.Row    = 1;
    btnFile.Layout.Column = 2;

    % Row 2 — filepath display
    fileLabel = uilabel(lg,'Text','(none)','FontColor',[0.4 0.4 0.4]);
    fileLabel.Layout.Row    = 2;
    fileLabel.Layout.Column = [1 2];

    % Row 3 — StimJim COM
    lblSJ = uilabel(lg,'Text','StimJim COM:');
    lblSJ.Layout.Row    = 3;
    lblSJ.Layout.Column = 1;
    ddStimjim = uidropdown(lg,'Items',{});
    ddStimjim.Layout.Row    = 3;
    ddStimjim.Layout.Column = 2;

    % Row 4 — DataLogger COM
    lblDL = uilabel(lg,'Text','DataLogger COM:');
    lblDL.Layout.Row    = 4;
    lblDL.Layout.Column = 1;
    ddLogger = uidropdown(lg,'Items',{});
    ddLogger.Layout.Row    = 4;
    ddLogger.Layout.Column = 2;

    % Row 5 — Refresh ports
    btnRefreshPorts = uibutton(lg,'Text','Refresh COM ports',...
        'ButtonPushedFcn',@(~,~) refreshPorts());
    btnRefreshPorts.Layout.Row    = 5;
    btnRefreshPorts.Layout.Column = [1 2];

    % Row 6 — Load patterns
    btnLoad = uibutton(lg,'Text','Load patterns into StimJim',...
        'BackgroundColor',[0.85 0.85 0.85],...
        'ButtonPushedFcn',@loadPatterns);
    btnLoad.Layout.Row    = 6;
    btnLoad.Layout.Column = [1 2];

    % Row 7 — status label
    lblLoadStatus = uilabel(lg,'Text','','HorizontalAlignment','center',...
        'FontColor',[0.2 0.2 0.6]);
    lblLoadStatus.Layout.Row    = 7;
    lblLoadStatus.Layout.Column = [1 2];

    % Row 8 — calibration header
    lblCal = uilabel(lg,'Text','Calibration  (Voff  Vscl  Ioff  Iscl):',...
        'FontWeight','bold','FontSize',11);
    lblCal.Layout.Row    = 8;
    lblCal.Layout.Column = [1 2];

    % Row 9 — single calibration text field (space/comma separated)
    efCalib = uieditfield(lg,'text','Value','1952 41 2052 843');
    efCalib.Layout.Row    = 9;
    efCalib.Layout.Column = [1 2];

    % Row 10 — Start testing
    btnStart = uibutton(lg,'Text','> Start testing',...
        'BackgroundColor',[0.2 0.7 0.3],'FontColor','white','FontWeight','bold',...
        'FontSize',13,'Enable','off','ButtonPushedFcn',@startTesting);
    btnStart.Layout.Row    = 10;
    btnStart.Layout.Column = [1 2];

    % Row 11 — Save buttons
    bg = uigridlayout(lg,[1 2]);
    bg.Layout.Row    = 11;
    bg.Layout.Column = [1 2];
    bg.Padding     = [0 0 0 0];
    bg.ColumnWidth = {'1x','1x'};
    btnSaveData = uibutton(bg,'Text','Save data (.mat)','Enable','off',...
        'ButtonPushedFcn',@saveData);
    btnSaveFig  = uibutton(bg,'Text','Save graphs (.svg)','Enable','off',...
        'ButtonPushedFcn',@saveFigures);

    % Row 12 — Serial monitor panels (two small scrollable text areas)
    monGrid = uigridlayout(lg,[2 1]);
    monGrid.Layout.Row    = 12;
    monGrid.Layout.Column = [1 2];
    monGrid.Padding    = [0 0 0 0];
    monGrid.RowSpacing = 3;
    monGrid.RowHeight  = {'1x','1x'};

    sjMonPanel = uipanel(monGrid,'Title','StimJim RX');
    sjMonPanel.Layout.Row    = 1;
    sjMonPanel.Layout.Column = 1;
    taSJ = uitextarea(sjMonPanel,'Editable','off','Value',{''});
    taSJ.Units    = 'normalized';
    taSJ.Position = [0 0 1 1];

    dlMonPanel = uipanel(monGrid,'Title','DataLogger RX');
    dlMonPanel.Layout.Row    = 2;
    dlMonPanel.Layout.Column = 1;
    taDL = uitextarea(dlMonPanel,'Editable','off','Value',{''});
    taDL.Units    = 'normalized';
    taDL.Position = [0 0 1 1];

    %% --- RIGHT PANEL --------------------------------------------------
    rightPanel = uipanel(gl,'Title','Results','FontWeight','bold');
    rightPanel.Layout.Row    = 1;
    rightPanel.Layout.Column = 2;

    % 2 rows x 2 cols: axes left (tall), pattern list right, cmd text below
    rg = uigridlayout(rightPanel,[2 2]);
    rg.RowHeight   = {'4x','1x'};
    rg.ColumnWidth = {'5x','1x'};
    rg.Padding     = [4 4 4 4];

    % Both axes live inside a nested grid in col 1, rows 1-2
    % We use a nested grid for the two axes in col 1
    axGrid = uigridlayout(rg,[2 1]);
    axGrid.Layout.Row    = 1;
    axGrid.Layout.Column = 1;
    axGrid.Padding    = [0 0 0 0];
    axGrid.RowSpacing = 4;
    axGrid.RowHeight  = {'1x','1x'};

    axV = uiaxes(axGrid);
    axV.Layout.Row    = 1;
    axV.Layout.Column = 1;
    xlabel(axV,'Time (ms)'); ylabel(axV,'Voltage (V)');
    title(axV,'Voltage'); axV.XGrid = 'on'; axV.YGrid = 'on';
    hold(axV,'on');

    axI = uiaxes(axGrid);
    axI.Layout.Row    = 2;
    axI.Layout.Column = 1;
    xlabel(axI,'Time (ms)'); ylabel(axI,'Current (mA)');
    title(axI,'Current'); axI.XGrid = 'on'; axI.YGrid = 'on';
    hold(axI,'on');

    % Pattern list (col 2, rows 1-2)
    lblPats = uilabel(rg,'Text','Patterns','HorizontalAlignment','center',...
        'FontWeight','bold');
    lblPats.Layout.Row    = 1;
    lblPats.Layout.Column = 2;
    lbPatterns = uilistbox(rg,'Items',{},'ValueChangedFcn',@onPatternSelect);
    lbPatterns.Layout.Row    = 2;
    lbPatterns.Layout.Column = 2;

    % Stimulus commands text area (row 2 col 1)
    cmdPanel = uipanel(rg,'Title','Stimulus commands (parsed)');
    cmdPanel.Layout.Row    = 2;
    cmdPanel.Layout.Column = 1;
    taCmd = uitextarea(cmdPanel,'Editable','off','Value',{'(browse to a settings file)'});
    taCmd.Units    = 'normalized';
    taCmd.Position = [0 0 1 1];

    %% ----------------------------------------------------------------
    %  Initialise port list
    %% ----------------------------------------------------------------
    refreshPorts();

    %% ================================================================
    %  CALLBACKS
    %% ================================================================

    % ----------------------------------------------------------------
    function browseFile(~,~)
        [fn,fp] = uigetfile('*.txt','Select experiment settings file');
        if isequal(fn,0), return; end
        settingsFile = fullfile(fp,fn);
        fileLabel.Text = settingsFile;
        parseSettingsFile();
    end

    % ----------------------------------------------------------------
    function refreshPorts()
        ports = listArduinoPorts();
        if isempty(ports), ports = {'(none)'}; end
        ddStimjim.Items = ports;
        ddLogger.Items  = ports;
        n = numel(ports);
        % Default to last two ports (most recently plugged-in devices)
        if n >= 2
            ddStimjim.Value = ports{n-1};
            ddLogger.Value  = ports{n};
        elseif n == 1
            ddStimjim.Value = ports{1};
            ddLogger.Value  = ports{1};
        end
        appendMonitor(taSJ, sprintf('[%s] Port list refreshed: %s', timestamp(), strjoin(ports,', ')));
    end

    % ----------------------------------------------------------------
    function parseSettingsFile()
        if isempty(settingsFile), return; end
        try
            lines = readlines(settingsFile);
        catch
            fid = fopen(settingsFile,'r');
            rawTxt = fread(fid,'*char')';
            fclose(fid);
            lines = string(strsplit(rawTxt,'\n'));
        end

        pats    = struct([]);
        cmdStrs = {};
        for k = 12:numel(lines)
            ln = strtrim(char(lines(k)));
            if numel(ln) < 3 || ln(2) ~= ')', continue; end
            label = ln(1);
            if ~isstrprop(label,'digit'), continue; end
            pNum = str2double(label);

            ci = strfind(ln,' % ');
            if ~isempty(ci), ln = strtrim(ln(1:ci(1)-1)); end

            body = strtrim(ln(3:end));
            pi2  = strfind(body,' | ');
            if isempty(pi2), continue; end
            sjCmd = strtrim(body(pi2(1)+3:end));
            if isempty(sjCmd) || sjCmd(1) ~= 'S', continue; end

            rebuilt = rebuildSCommand(sjCmd, pNum, STIM_DURATION_US);
            if isempty(rebuilt), continue; end

            entry.patternNum  = pNum;
            entry.originalCmd = sjCmd;
            entry.sendCmd     = rebuilt;
            if isempty(pats), pats = entry;
            else,             pats(end+1) = entry; end %#ok<AGROW>
            cmdStrs{end+1} = sprintf('P%d: %s', pNum, rebuilt); %#ok<AGROW>
        end

        patterns = pats;
        if isempty(patterns)
            taCmd.Value = {'No stimulus patterns found.'};
            uialert(fig,'No digit-labelled StimJim S commands found.','Parse error');
            return;
        end
        taCmd.Value = cmdStrs(:);
        btnLoad.Enable = 'on';
        setStatus(sprintf('%d pattern(s) parsed. Select COM ports then click Load.', numel(patterns)));
    end

    % ----------------------------------------------------------------
    function loadPatterns(~,~)
        if isempty(patterns)
            uialert(fig,'Browse to a settings file first.','No patterns'); return;
        end

        %% Open StimJim port
        sjPortName = ddStimjim.Value;
        if strcmp(sjPortName,'(none)')
            uialert(fig,'Select a StimJim COM port.','No port'); return;
        end
        setStatus('Opening StimJim port...');
        try
            if ~isempty(sjPort) && isvalid(sjPort), delete(sjPort); end
            sjPort = serialport(sjPortName, SERIAL_BAUD, 'Timeout', 5);
            configureTerminator(sjPort, 'CR/LF');
            flush(sjPort);
        catch ME
            uialert(fig, ME.message, 'StimJim port error'); return;
        end
        appendMonitor(taSJ, sprintf('[%s] Opened %s at %d baud', timestamp(), sjPortName, SERIAL_BAUD));

        %% Send each S# command, read ack with generous wait
        allOk = true;
        for p = 1:numel(patterns)
            cmd = patterns(p).sendCmd;
            setStatus(sprintf('Sending pattern %d/%d: %s', p, numel(patterns), cmd));
            flush(sjPort);
            writeline(sjPort, cmd);
            appendMonitor(taSJ, sprintf('[%s] TX: %s', timestamp(), cmd));

            % Wait up to SJ_ACK_PAUSE seconds, reading byte-by-byte
            resp  = '';
            accum = '';
            t0 = tic;
            while toc(t0) < SJ_ACK_PAUSE
                nb = sjPort.NumBytesAvailable;
                if nb > 0
                    bytes = read(sjPort, nb, 'uint8');
                    for bi = 1:numel(bytes)
                        ch = char(bytes(bi));
                        if ch == newline || ch == char(13)   % LF or CR
                            ln = strtrim(accum);
                            accum = '';
                            if ~isempty(ln)
                                resp = [resp, ln, ' | ']; %#ok<AGROW>
                                appendMonitor(taSJ, sprintf('[%s] RX: %s', timestamp(), ln));
                            end
                        else
                            accum = [accum, ch]; %#ok<AGROW>
                        end
                    end
                else
                    pause(0.02);
                end
            end
            % Flush any partial line still in accumulator
            if ~isempty(strtrim(accum))
                resp = [resp, strtrim(accum), ' | '];
                appendMonitor(taSJ, sprintf('[%s] RX: %s', timestamp(), strtrim(accum)));
            end

            % StimJim printPulseTrainParameters always prints "mV" and "uA"
            ok = contains(resp,'mV') || contains(resp,'uA') || contains(resp,'Parameters');
            if ok
                appendMonitor(taSJ, sprintf('[%s] Pattern %d ACK OK', timestamp(), patterns(p).patternNum));
            else
                appendMonitor(taSJ, sprintf('[%s] WARNING: No ACK for pattern %d (got: %s)',...
                    timestamp(), patterns(p).patternNum, resp));
                allOk = false;
            end
            drawnow;
        end

        %% Open DataLogger port
        dlPortName = ddLogger.Value;
        if strcmp(dlPortName,'(none)')
            uialert(fig,'Select a DataLogger COM port.','No port'); return;
        end
        setStatus('Opening DataLogger port...');
        try
            if ~isempty(dlPort) && isvalid(dlPort), delete(dlPort); end
            dlPort = serialport(dlPortName, SERIAL_BAUD, 'Timeout', 10);
            configureTerminator(dlPort, 'CR/LF');
            flush(dlPort);
        catch ME
            uialert(fig, ME.message, 'DataLogger port error'); return;
        end
        appendMonitor(taDL, sprintf('[%s] Opened %s at %d baud', timestamp(), dlPortName, SERIAL_BAUD));

        %% Initialise DataLogger: i50, n2, L0 with pause and readback
        loggerInitCmds = {'i50','n2','L0'};
        loggerInitDesc = {'sample interval 50us (20kHz)','2 channels','no trigger limit'};
        for ci = 1:3
            setStatus(sprintf('DataLogger init: %s (%s)...', loggerInitCmds{ci}, loggerInitDesc{ci}));
            flush(dlPort);
            writeline(dlPort, loggerInitCmds{ci});
            appendMonitor(taDL, sprintf('[%s] TX: %s', timestamp(), loggerInitCmds{ci}));
            pause(LOGGER_INIT_PAUSE);
            dlAccum = '';
            t1 = tic;
            while toc(t1) < 0.5   % drain for 0.5s after pause
                nb = dlPort.NumBytesAvailable;
                if nb > 0
                    bytes = read(dlPort, nb, 'uint8');
                    for bi = 1:numel(bytes)
                        ch = char(bytes(bi));
                        if ch == newline || ch == char(13)
                            ln = strtrim(dlAccum);
                            dlAccum = '';
                            if ~isempty(ln)
                                appendMonitor(taDL, sprintf('[%s] RX: %s', timestamp(), ln));
                            end
                        else
                            dlAccum = [dlAccum, ch]; %#ok<AGROW>
                        end
                    end
                else
                    pause(0.02);
                end
            end
            drawnow;
        end

        loggerReady = true;
        btnLoad.BackgroundColor = [0.3 0.8 0.3];
        btnStart.Enable = 'on';
        if allOk
            setStatus('All patterns loaded. Logger ready. Click Start testing.');
        else
            setStatus('Patterns loaded with warnings (check StimJim monitor). Logger ready.');
        end
        drawnow;
    end

    % ----------------------------------------------------------------
    function startTesting(~,~)
        if isempty(patterns) || ~loggerReady
            uialert(fig,'Load patterns first.','Not ready'); return;
        end
        btnStart.Enable    = 'off';
        btnSaveData.Enable = 'off';
        btnSaveFig.Enable  = 'off';
        resultData    = struct([]);
        lbPatterns.Items = {};
        saveTimestamp = char(datetime('now','Format','yyyy-MM-dd_HH-mm-ss'));

        for p = 1:numel(patterns)
            if ~isvalid(fig), break; end
            pNum    = patterns(p).patternNum;
            trigCmd = sprintf('T%d', pNum);

            setStatus(sprintf('Testing pattern %d/%d - sending %s...', p, numel(patterns), trigCmd));

            % Trigger StimJim first — stimulation begins immediately.
            % Then send "m" to DataLogger as fast as possible.
            % "m" starts a fixed 100 ms capture window right away with no
            % arming delay, so the capture must be issued while the pulse
            % is still in progress. The serial write itself takes only a
            % few ms, so the capture window will overlap the pulse as long
            % as STIM_DURATION_US >> 100 ms. If the pulse is very short,
            % consider increasing STIM_DURATION_US.
            flush(sjPort);
            writeline(sjPort, trigCmd);
            appendMonitor(taSJ, sprintf('[%s] TX: %s', timestamp(), trigCmd));

            % Send "m" immediately after — no pause
            flush(dlPort);
            writeline(dlPort, 'm');
            appendMonitor(taDL, sprintf('[%s] TX: m (100 ms capture started)', timestamp()));

            % Read capture data (3 cols: time_us, V_raw, I_raw)
            raw = readLoggerCapture(dlPort, taDL, @timestamp, @appendMonitor);

            % Store result
            entry.patternNum = pNum;
            entry.sendCmd    = patterns(p).sendCmd;
            entry.triggerCmd = trigCmd;
            entry.timestamp  = saveTimestamp;
            entry.rawData    = raw;   % Nx3: [time_us, V_raw, I_raw]
            if isempty(resultData), resultData = entry;
            else,                   resultData(end+1) = entry; end %#ok<AGROW>

            % Update pattern list and plot
            items = lbPatterns.Items;
            items{end+1} = sprintf('Pattern %d', pNum);
            lbPatterns.Items = items;
            lbPatterns.Value = items{end};
            plotPattern(p);

            setStatus(sprintf('Pattern %d captured (%d points). Waiting...', pNum, size(raw,1)));
            pause(max(0, TOTAL_TIME_PER_PAT - 0.1));
        end

        % Force StimJim stop
        writeline(sjPort,'T-1');
        appendMonitor(taSJ, sprintf('[%s] TX: T-1 (stop)', timestamp()));

        setStatus(sprintf('Done. %d pattern(s) captured.', numel(resultData)));
        btnStart.Enable    = 'on';
        btnSaveData.Enable = 'on';
        btnSaveFig.Enable  = 'on';
        drawnow;
    end

    % ----------------------------------------------------------------
    function onPatternSelect(~,~)
        idx = find(strcmp(lbPatterns.Items, lbPatterns.Value),1);
        if ~isempty(idx) && idx <= numel(resultData)
            plotPattern(idx);
        end
    end

    % ----------------------------------------------------------------
    function plotPattern(idx)
        if idx > numel(resultData), return; end
        d = resultData(idx);
        if isempty(d.rawData) || size(d.rawData,1) < 2, return; end

        % Parse calibration from single text box
        [Voff, Vscl, Ioff, Iscl] = parseCalib(efCalib.Value);

        % Columns from DataLogger memory mode: time_us | V_raw | I_raw
        t_us = d.rawData(:,1);
        Vraw = d.rawData(:,2);
        Iraw = d.rawData(:,3);

        % Normalise time to start at 0, convert to ms
        t_ms = (t_us - t_us(1)) / 1000;

        Vcal = (Vraw - Voff) / Vscl;
        Ical = (Iraw - Ioff) / Iscl;
        zero = zeros(size(t_ms));

        % --- Voltage axes ---
        cla(axV); hold(axV,'on');
        fill(axV, [t_ms; flipud(t_ms)], [Vcal; flipud(zero)], [0.2 0.5 0.9], ...
            'FaceAlpha',0.3,'EdgeColor','none');
        plot(axV, t_ms, Vcal, 'Color',[0.1 0.3 0.8], 'LineWidth',1.5);
        yline(axV, 0, 'k-', 'LineWidth',0.8);
        xlabel(axV,'Time (ms)'); ylabel(axV,'Voltage (V)');
        title(axV, sprintf('Pattern %d - Voltage', d.patternNum));
        axV.XGrid = 'on'; axV.YGrid = 'on';

        % --- Current axes ---
        cla(axI); hold(axI,'on');
        fill(axI, [t_ms; flipud(t_ms)], [Ical; flipud(zero)], [0.9 0.3 0.2], ...
            'FaceAlpha',0.3,'EdgeColor','none');
        plot(axI, t_ms, Ical, 'Color',[0.8 0.1 0.1], 'LineWidth',1.5);
        yline(axI, 0, 'k-', 'LineWidth',0.8);
        xlabel(axI,'Time (ms)'); ylabel(axI,'Current (mA)');
        title(axI, sprintf('Pattern %d - Current', d.patternNum));
        axI.XGrid = 'on'; axI.YGrid = 'on';

        drawnow;
    end

    % ----------------------------------------------------------------
    function saveData(~,~)
        if isempty(resultData)
            uialert(fig,'No data to save.','Empty'); return;
        end
        if ~isfolder(ESTIM_FOLDER), mkdir(ESTIM_FOLDER); end
        fname = fullfile(ESTIM_FOLDER, ['StimValidation_' saveTimestamp '.mat']);
        save(fname,'resultData');
        setStatus(['Data saved: ' fname]);
        uialert(fig,['Saved: ' fname],'Saved','Icon','success');
    end

    % ----------------------------------------------------------------
    function saveFigures(~,~)
        % For each pattern: update the live GUI axes (plotPattern), then
        % render the same data into a hidden regular figure for export.
        % Uses only saveas(.svg) which works in R2021a and R2025b.
        % uiaxes cannot be copyobj'd to a figure; we replot from raw data.
        if isempty(resultData)
            uialert(fig,'No data to save.','Empty'); return;
        end
        if ~isfolder(ESTIM_FOLDER), mkdir(ESTIM_FOLDER); end

        [Voff, Vscl, Ioff, Iscl] = parseCalib(efCalib.Value);

        for idx = 1:numel(resultData)
            plotPattern(idx);   % keep live GUI display in sync
            drawnow;

            d    = resultData(idx);
            pNum = d.patternNum;
            base = fullfile(ESTIM_FOLDER, ...
                sprintf('StimValidation_%s_P%d', saveTimestamp, pNum));

            if isempty(d.rawData) || size(d.rawData,1) < 2
                setStatus(sprintf('Pattern %d: no data to save', pNum));
                continue;
            end

            t_ms = (d.rawData(:,1) - d.rawData(1,1)) / 1000;
            Vcal = (d.rawData(:,2) - Voff) / Vscl;
            Ical = (d.rawData(:,3) - Ioff) / Iscl;
            zero = zeros(size(t_ms));

            % Create hidden regular figure - works in all versions
            fh = figure('Visible','off','Position',[50 50 900 540]);

            axV2 = subplot(2,1,1);
            hold(axV2,'on');
            fill(axV2,[t_ms;flipud(t_ms)],[Vcal;flipud(zero)],[0.2 0.5 0.9],...
                'FaceAlpha',0.3,'EdgeColor','none');
            plot(axV2,t_ms,Vcal,'Color',[0.1 0.3 0.8],'LineWidth',1.5);
            yline(axV2,0,'k-','LineWidth',0.8);
            xlabel(axV2,'Time (ms)'); ylabel(axV2,'Voltage (V)');
            title(axV2, sprintf('Pattern %d - Voltage', pNum));
            grid(axV2,'on');

            axI2 = subplot(2,1,2);
            hold(axI2,'on');
            fill(axI2,[t_ms;flipud(t_ms)],[Ical;flipud(zero)],[0.9 0.3 0.2],...
                'FaceAlpha',0.3,'EdgeColor','none');
            plot(axI2,t_ms,Ical,'Color',[0.8 0.1 0.1],'LineWidth',1.5);
            yline(axI2,0,'k-','LineWidth',0.8);
            xlabel(axI2,'Time (ms)'); ylabel(axI2,'Current (mA)');
            title(axI2, sprintf('Pattern %d - Current', pNum));
            grid(axI2,'on');

            saveas(fh, [base '.svg']);
            saveas(fh, [base '.fig']);
            close(fh);

            setStatus(sprintf('Saved graph %d/%d', idx, numel(resultData)));
            drawnow;
        end
        uialert(fig, sprintf('%d graph(s) saved to %s', numel(resultData), ESTIM_FOLDER),...
            'Saved','Icon','success');
    end

    % ----------------------------------------------------------------
    function onClose(~,~)
        try
            if ~isempty(sjPort) && isvalid(sjPort)
                writeline(sjPort,'T-1');
                delete(sjPort);
            end
        catch, end
        try
            if ~isempty(dlPort) && isvalid(dlPort), delete(dlPort); end
        catch, end
        delete(fig);
    end

    %% ================================================================
    %  Utility sub-functions (nested, access shared state)
    %% ================================================================

    function setStatus(msg)
        lblLoadStatus.Text = msg;
        drawnow;
    end

    function appendMonitor(ta, msg)
        % Append a line to a serial monitor text area, keep last 200 lines
        v = ta.Value;
        if isempty(v) || (numel(v)==1 && isempty(char(v{1}))), v = {}; end
        v{end+1} = msg;
        if numel(v) > 200, v = v(end-199:end); end
        ta.Value = v;
        % Scroll to bottom by triggering a layout update
        drawnow;
    end

    function ts = timestamp()
        ts = char(datetime('now','Format','HH:mm:ss.SSS'));
    end

    function [Voff, Vscl, Ioff, Iscl] = parseCalib(str)
        % Parse 4 numbers from space- or comma-separated string
        nums = str2double(strsplit(strtrim(str), {' ',',','\t'}, 'CollapseDelimiters',true));
        nums = nums(~isnan(nums));
        defaults = [1952, 41, 2052, 843];
        if numel(nums) < 4, nums = [nums, defaults(numel(nums)+1:end)]; end
        Voff = nums(1); Vscl = nums(2); Ioff = nums(3); Iscl = nums(4);
    end

end % StimValidationGUI


%% ====================================================================
%  MODULE-LEVEL HELPERS  (no access to GUI state)
%% ====================================================================

function ports = listArduinoPorts()
    ports = {};
    try
        info = serialportlist('available');
        for k = 1:numel(info)
            p = char(info(k));
            if contains(p,'COM','IgnoreCase',true)    || ...
               contains(p,'usbmodem','IgnoreCase',true) || ...
               contains(p,'usbserial','IgnoreCase',true)
                ports{end+1} = p; %#ok<AGROW>
            end
        end
        if isempty(ports)
            for k = 1:numel(info)
                ports{end+1} = char(info(k)); %#ok<AGROW>
            end
        end
    catch
        ports = {};
    end
end

% -----------------------------------------------------------------------
function rebuilt = rebuildSCommand(originalCmd, patternNumber, newDurationUs)
% Replace slot index (field 1) and duration_us (field 5) in an S command.
% Everything after the first ";" (stage blocks) is preserved verbatim.
    rebuilt = '';
    semi = strfind(originalCmd,';');
    if isempty(semi), return; end
    header = strtrim(originalCmd(1:semi(1)-1));
    stages = originalCmd(semi(1):end);
    fields = strsplit(header,',');
    if numel(fields) < 5, return; end
    fields{1} = sprintf('S%d', patternNumber);
    fields{5} = sprintf('%d',  newDurationUs);
    rebuilt = [strjoin(fields,','), stages];
end

% -----------------------------------------------------------------------
function raw = readLoggerCapture(dlPort, taDL, timestampFn, appendFn)
% Read fast-capture stream from DataLogger after "m" command.
%
% Uses byte-level reading to avoid readline() blocking on terminator.
% Builds lines manually from the byte stream; a line is complete on CR or LF.
%
% DataLogger memory-mode output: one sample per line, 3 comma-separated
% integers:   time_us, V_raw, I_raw
%
% Capture ends when:
%   (a) a blank line is received (firmware sends one after the burst), or
%   (b) a line starting with "Done"/"End" is received, or
%   (c) no new bytes arrive for IDLE_TIMEOUT seconds (burst exhausted), or
%   (d) HARD_TIMEOUT seconds elapsed.
%
% Returns Nx3 matrix [time_us, V_raw, I_raw].
    raw          = zeros(0,3);
    accum        = '';          % partial line buffer
    tHard        = tic;
    tIdle        = tic;
    IDLE_TIMEOUT = 1.0;         % s of silence = capture done
    HARD_TIMEOUT = 15.0;        % s absolute limit
    done         = false;
    nLog         = 0;           % lines logged to monitor (limit noise)
    MAX_LOG      = 10;          % only log first/last few lines to monitor

    while ~done && toc(tHard) < HARD_TIMEOUT
        nb = dlPort.NumBytesAvailable;
        if nb > 0
            tIdle = tic;                        % reset idle timer
            bytes = read(dlPort, nb, 'uint8');
            for bi = 1:numel(bytes)
                ch = char(bytes(bi));
                if ch == newline || ch == char(13)   % LF or CR terminates a line
                    ln = strtrim(accum);
                    accum = '';
                    if isempty(ln), continue; end   % skip bare CR before LF

                    % Log first MAX_LOG and last few lines to monitor
                    nLog = nLog + 1;
                    if nLog <= MAX_LOG
                        appendFn(taDL, sprintf('[%s] RX: %s', timestampFn(), ln));
                    elseif nLog == MAX_LOG + 1
                        appendFn(taDL, sprintf('[%s] RX: ... (logging every 100th line)', timestampFn()));
                    elseif mod(nLog, 100) == 0
                        appendFn(taDL, sprintf('[%s] RX: %s  (%d pts so far)', timestampFn(), ln, size(raw,1)));
                    end

                    % Terminal conditions
                    if strncmpi(ln,'Done',4) || strncmpi(ln,'End',3)
                        appendFn(taDL, sprintf('[%s] Capture ended by firmware: %s', timestampFn(), ln));
                        done = true; break;
                    end

                    % Parse: time_us, V_raw, I_raw
                    vals = str2double(strsplit(ln, ','));
                    if numel(vals) >= 3 && ~any(isnan(vals(1:3)))
                        raw(end+1,:) = vals(1:3); %#ok<AGROW>
                    elseif numel(vals) == 2 && ~any(isnan(vals))
                        % 2-column fallback (no timestamp from firmware)
                        raw(end+1,:) = [(size(raw,1)) * 50, vals(1), vals(2)]; %#ok<AGROW>
                    else
                        appendFn(taDL, sprintf('[%s] RX (skip): %s', timestampFn(), ln));
                    end
                else
                    accum = [accum, ch]; %#ok<AGROW>
                end
            end
        else
            if toc(tIdle) > IDLE_TIMEOUT
                done = true;
                appendFn(taDL, sprintf('[%s] Capture complete: %d points (idle timeout)', ...
                    timestampFn(), size(raw,1)));
            else
                pause(0.005);
            end
        end
    end

    if toc(tHard) >= HARD_TIMEOUT
        appendFn(taDL, sprintf('[%s] WARNING: Hard timeout - %d points captured', ...
            timestampFn(), size(raw,1)));
    end
end
