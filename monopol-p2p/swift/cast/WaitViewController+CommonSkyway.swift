//
//  WaitViewController+CommonSkyway.swift
//  swift_skyway
//
//  Created by onda on 2018/09/01.
//  Copyright © 2018年 worldtrip. All rights reserved.
//

import SkyWay
import AVFoundation

// MARK: setup skyway
extension WaitViewController{

    func startConnection() {
        print("[DIAG][FLOW] startConnection ENTER waitState=\(waitState) useNewSDK=\(useNewSDK) isSkyWayReady=\(isSkyWayReady) peer=\(peer != nil) localStream=\(appDelegate.localStream != nil) \(SkywayManager.sharedManager().diagPublishState)")
        print("[DIAG][START_CONN] step=enter thread=\(Thread.isMainThread ? "MT" : "BG")")
        print("[WAITREQ][RECV] entering function=startConnection useNewSDK=\(useNewSDK)")
        print("[WAITREQ][TIMER] startConnection: called timerIsValid=\(castWaitDialog.requestTimer.isValid) timerCount=\(castWaitDialog.timerCount) requestWaitFlg=\(castWaitDialog.requestWaitFlg)")
        //（一時的異常状態に）初期化する
        self.listenerErrorFlg = 0
        //正常状態に初期化する
        self.listenerStatus = 0//重要

        self.castSelectedDialog.isHidden = true
        print("[DIAG][START_CONN] step=before_async_block")

        DispatchQueue.main.async {
            print("[DIAG][START_CONN] step=inside_async_block isReconnect=\(self.isReconnect)")

            /*******************************/
            //処理するタイミングをここに変更
            /*******************************/
            //念の為、ここでも非表示
            self.castWaitDialog.topInfoLabel.isHidden = true

            // タイムアウトのタイマーを無効にする
            print("[WAITREQ][TIMER] startConnection: invalidating requestTimer timerCount=\(self.castWaitDialog.timerCount)")
            self.castWaitDialog.requestTimer.invalidate()
            
            //status 1:申請中 2:申請したけど拒否された 99:接続が承認された
            let myLivePoint = UserDefaults.standard.integer(forKey: "myLivePoint")
            
            //print(self.appDelegate.init_seconds)
            
            if(self.isReconnect == false)
            {
                /***************************************************/
                //スターの追加処理
                /***************************************************/
                //得られるスター数
                let star_num = UserDefaults.standard.integer(forKey: "get_live_point")
                //必要なコイン
                let coin_num = UserDefaults.standard.double(forKey: "coin")
                
                //現在のスター数
                let star_temp = UserDefaults.standard.integer(forKey: "live_now_star")
                UserDefaults.standard.set(star_temp + star_num, forKey: "live_now_star")
                
                //mySQL更新(スター加算)
                //配信時の獲得ポイント1コインにつき1
                //Util.LIVE_POINT_GET: Int = 1
                //1枠の配信成立
                //Util.LIVE_POINT_GET_ONE: Double = 50
                let livePointGet = Util.LIVE_POINT_GET_ONE + (Int(coin_num) * Util.LIVE_POINT_GET)
                
                //重要(リアルタイムデータベースを使用)
                self.conditionRef = self.rootRef.child(Util.INIT_FIREBASE + "/"
                    + String(self.user_id) + "/" + String(self.appDelegate.live_target_user_id))
                let data = ["cast_live_point": myLivePoint + livePointGet, "effect_id": self.appDelegate.live_effect_id]
                self.conditionRef.updateChildValues(data)
                //配信レベルの処理
                //user_infoテーブルの更新（キャスト）
                //flg:1:値プラス、2:値マイナス
                //GET: user_id, point,star,live_count,seconds,flg
                //１枠の秒数を設定
                self.appDelegate.init_seconds = UserDefaults.standard.integer(forKey: "live_sec")
                
                //配信経験値履歴にキャストが得た配信経験値などの履歴を保存する
                UtilFunc.writeLivePointRireki(type:1, cast_id:self.user_id, user_id:self.appDelegate.live_target_user_id, point:livePointGet, star:star_num, seconds:self.appDelegate.init_seconds, re_star:0)
                
                UtilFunc.saveLiveLevelNew(user_id:self.user_id, point:livePointGet, star:star_num, live_count:1, seconds:self.appDelegate.init_seconds, flg:1)
                
                //アプリ内の値を更新
                UtilFunc.setMyInfo()
                
                //配信時間の初期化
                self.appDelegate.count = 0
                
                //接続状態(会話開始状態)へ
                //self.removeFromSuperview()
                self.castWaitDialog.waitDialogView.isHidden = true
                self.castWaitDialog.statusLbl.isHidden = true
                
                self.castWaitDialog.allCoverMessage.isHidden = true
                self.castWaitDialog.allCoverRequest.isHidden = true
                self.castWaitDialog.topInfoLabel.isHidden = true

                //ライブ開始のタイムスタンプ
                //1:待機スタート 2:ライブ開始 3:ライブ後の待機 4：待機解除 5:運営タイムスタンプ（待機確認）
                UtilFunc.addActionRireki(user_id: self.user_id, listener_id: self.appDelegate.live_target_user_id, type: 2, value01:0, value02:0)
                
                //リクエスト状態の更新（リクエスト後に配信までしたのかなどの状態>最新の一件のみ更新）
                //GET:user_id, listener_user_id, request_status
                //request_status 1:リクエスト後配信 2:リクエスト後キャストが拒否 3:リクエストしてそのまま
                UtilFunc.modifyLiveRequestStatusByOne(user_id:self.user_id, listener_user_id:self.appDelegate.live_target_user_id, request_status:1)
            }

            self.isReconnect = false
            
        }

        //通信時のSDK内部の処理の影響に依り、STREAMのコールバックで設定するとうまく設定出来ず、
        //STREAMイベントを受けた後に1秒ほどdelayを挟んで上記の設定を行うとスピーカより出力されるかと思います。
        //DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // 2.0秒後に実行したい処理
            //print("スピーカーから出力させる")
            //スピーカーから出力させる
            //let audioSession = AVAudioSession.sharedInstance()
        //    self.addAudioSessionObservers()
        //}
        //self.addAudioSessionObservers()
        print("[DIAG][START_CONN] step=exit_complete")
    }

    func closeMedia() {

        if self.mediaConnection != nil{
            self.mediaConnection!.close()
            self.mediaConnection!.on(.MEDIACONNECTION_EVENT_STREAM, callback: nil)
            self.mediaConnection!.on(.MEDIACONNECTION_EVENT_CLOSE, callback: nil)
            self.mediaConnection!.on(.MEDIACONNECTION_EVENT_ERROR, callback: nil)
            self.mediaConnection = nil
        }
        
        //ローカルストリームを一時停止
        //self.appDelegate.localStream?.setEnableVideoTrack(0, enable: false)
    }
    
    func sessionClose() {
        // 再入防止ガード
        guard !isSessionClosing else {
            print("[NewSDK] sessionClose: already closing, skipping")
            return
        }
        isSessionClosing = true
        print("[SESSION] sessionClose START thread=\(Thread.isMainThread ? "MT" : "BG") cast_id=\(user_id) isCancelWaitFlow=\(isCancelWaitFlow) isLiveConnectionStarted=\(isLiveConnectionStarted)")

        // 解除中: 配信UIを非表示にし操作を無効化
        Task { @MainActor in
            self.setWaitState(.stopping)
        }
        defer { isLiveConnectionStarted = false }

        // 旧 Peer SDK クリーンアップ（peer が存在する場合のみ）
        if let peer = self.peer {
            peer.on(.PEER_EVENT_OPEN, callback: nil)
            peer.on(.PEER_EVENT_CLOSE, callback: nil)
            peer.on(.PEER_EVENT_CALL, callback: nil)
            peer.on(.PEER_EVENT_DISCONNECTED, callback: nil)
            peer.on(.PEER_EVENT_ERROR, callback: nil)
            print("[SESSION] sessionClose: peer.destroy START thread=\(Thread.isMainThread ? "MT" : "BG")")
            peer.destroy()
            print("[SESSION] sessionClose: peer.destroy END")
            self.peer = nil
        }

        // 新 SDK 後始末（room/member が nil でも安全、idempotent）
        // leaveRoomIfNeeded() はバックグラウンドで実行し、完了時のみ MainActor で通知
        print("[SESSION] sessionClose: launching leaveRoomIfNeeded Task thread=\(Thread.isMainThread ? "MT" : "BG")")
        Task {
            await SkywayManager.sharedManager().leaveRoomIfNeeded(reason: "WaitVC.sessionClose")
            await MainActor.run {
                self.onSessionCloseCompleted()
            }
        }

        // タイムアウト（12秒）: leave がハングした場合の強制復帰
        sessionCloseTimeoutTask?.cancel()
        sessionCloseTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            print("[NewSDK] sessionClose: TIMEOUT after 12s, forcing recovery")
            self.onSessionCloseCompleted()
        }
    }

    @MainActor
    private func onSessionCloseCompleted() {
        // 冪等: 1回のみ実行
        guard isSessionClosing else { return }
        isSessionClosing = false
        sessionCloseCompletedOnce = true

        // タイムアウトタスクをキャンセル
        sessionCloseTimeoutTask?.cancel()
        sessionCloseTimeoutTask = nil

        // Firebase request node のクリーンアップ（前回データ残留防止）
        self.rootRef.child(Util.INIT_FIREBASE + "/" + String(self.user_id)).removeValue()
        print("[NewSDK] sessionClose: Firebase userrequest/\(self.user_id) removed")

        // 状態フラグの完全リセット
        isLiveConnectionStarted = false
        isNewSDKReadyForApproval = false
        isPendingApproval = false
        pendingApprovalCompletion = nil
        pendingRequest = nil

        print("[NewSDK] sessionClose completed, transitioning to .idle")
        self.setWaitState(.idle)

        // cancelWait ボタン経由の場合のみ画面遷移を実行
        if isCancelWaitFlow {
            self.castWaitDialog.cancelWaitCompleted()
        }
        isCancelWaitFlow = false
    }
    
    //type=0:初期化あり(最初一度だけ実行)
    func setup(){
        // NewSDKモードでは旧Peer SDKの初期化を完全にスキップ
        // setupStream() 内の SKWNavigator.initialize / getUserMedia が
        // NewSDKのカメラソース(CameraVideoSource)と競合し sender.cpp:78 クラッシュの原因となる
        if useNewSDK {
            print("[DIAG][SETUP] SKIP old peer setup: useNewSDK=true waitState=\(waitState)")
            return
        }
        //待機状態へ遷移するためロックする
        /******************************/
        //ロック
        /******************************/
        //GET:user_id,type(1:待機状態への遷移ロック)
        UtilFunc.addCastLock(cast_id:self.user_id, user_id:self.user_id, type:1)
        /******************************/
        //ロック(ここまで)
        /******************************/
        
        //くるくる表示開始
        if(self.busyIndicator.isDescendant(of: self.view)){
            //すでに追加(addsubview)済み
            //画面サイズに合わせる
            self.busyIndicator.frame = self.view.frame
            self.view.bringSubviewToFront(self.busyIndicator)
        }else{
            //画面サイズに合わせる
            self.busyIndicator.frame = self.view.frame
            // 貼り付ける
            self.view.addSubview(self.busyIndicator)
            self.view.bringSubviewToFront(self.busyIndicator)
        }
        
        // peer が nil / destroyed / disconnected なら再作成
        let needsNewPeer: Bool = {
            guard let p = self.peer else { return true }
            return p.isDestroyed || p.isDisconnected
        }()

        if needsNewPeer {
            print("[SKYWAY] setup: peer is nil/destroyed/disconnected — creating new peer")
            self.isSkyWayReady = false
            let option: SKWPeerOption = SKWPeerOption.init();
            option.key = Util.skywayAPIKey
            option.domain = Util.skywayDomain

            //idにはuser_idを入れる
            self.peer = SKWPeer(id: String(self.user_id), options: option)
            if let _peer = self.peer{
                self.setupPeerCallBacks(peer: _peer)
                self.setupStream(peer: _peer)
            }else{
                print("[SKYWAY_ERR] setup: failed to create peer")
            }
        }else{
            guard let peer = self.peer else {
                print("[SKYWAY_ERR] setup: peer became nil unexpectedly after needsNewPeer check")
                return
            }
            UtilFunc.isPeerIdExist(peer: peer, peerId: String(self.user_id)){ (flg) in
                if(flg == false){
                    //接続されていない場合(バックグラウンドにある場合)
                    //self.appDelegate.peer!.disconnect()
                    //self.appDelegate.peer!.destroy()
                    //self.appDelegate.peer = nil

                    //正常状態(人的操作によるもの)にする
                    self.listenerErrorFlg = 1
                    self.appDelegate.localStream?.removeVideoRenderer(self.localStreamView, track: 0)

                    self.isSkyWayReady = false
                    let option: SKWPeerOption = SKWPeerOption.init();
                    option.key = Util.skywayAPIKey
                    option.domain = Util.skywayDomain

                    //idにはuser_idを入れる
                    self.peer = SKWPeer(id: String(self.user_id), options: option)

                    if let _peer = self.peer{
                        self.setupPeerCallBacks(peer: _peer)
                        self.setupStream(peer: _peer)
                    }else{
                        print("[SKYWAY_ERR] setup: failed to create peer (reconnect path)")
                    }

                }else{
                    //PEERだけが繋がっている場合
                }
            }
        }
        
        self.busyIndicator.removeFromSuperview()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            //5秒後にロック解除（念のため）
            //GET:user_id,type(1:待機状態への遷移ロック)
            UtilFunc.deleteCastLock(cast_id:self.user_id, user_id:self.user_id, type:1)
        }
    }
    
    func setupStream(peer:SKWPeer){
        //下記はエミュレーターだとエラーとなる
        SKWNavigator.initialize(peer)
        let constraints:SKWMediaConstraints = SKWMediaConstraints()
        self.appDelegate.localStream = SKWNavigator.getUserMedia(constraints)

        self.appDelegate.localStream?.addVideoRenderer(self.localStreamView, track: 0)
    }
    
    //通話の接続
    func call(targetPeerId:String){
        guard let peer = self.peer else {
            print("[SKYWAY_ERR] call: peer is nil, cannot call targetPeerId=\(targetPeerId)")
            return
        }
        let option = SKWCallOption()
        print("[PUBTRACE] file=WaitVC+CommonSkyway func=call kind=peer.call useNewSDK=\(useNewSDK) localStream=\(self.appDelegate.localStream != nil) targetPeerId=\(targetPeerId) BEFORE")
        if let mediaConnection = peer.call(withId: targetPeerId, stream: self.appDelegate.localStream, options: option){
            self.mediaConnection = mediaConnection
            self.setupMediaConnectionCallbacks(mediaConnection: mediaConnection)
        }else{
            print("failed to call :\(targetPeerId)")
        }
    }
    
    //チャットの接続
    func connect(targetPeerId:String){
        guard let peer = self.peer else {
            print("[SKYWAY_ERR] connect: peer is nil, cannot connect targetPeerId=\(targetPeerId)")
            return
        }
        let options = SKWConnectOption()
        options.serialization = SKWSerializationEnum.SERIALIZATION_BINARY

        //接続
        if let dataConnection = peer.connect(withId: targetPeerId, options: options){
            self.dataConnection = dataConnection
            self.setupDataConnectionCallbacks(dataConnection: dataConnection)
        }else{
            print("failed to connect data connection")
        }
    }
}

// MARK: - SkyWay Reconnect
extension WaitViewController {
    /// SkyWay再接続（リクエスト受信時/承認時にisSkyWayReady=falseの場合）
    /// 多重発火防止付き。15秒タイムアウトで1回だけリトライ。2回目失敗でユーザー通知。
    func setupSkyWayReconnect(reason: String) {
        // NewSDKモードでは旧Peer SDKの再接続は不要
        if useNewSDK {
            print("[DIAG][RECONNECT] SKIP setupSkyWayReconnect: useNewSDK=true reason=\(reason)")
            return
        }
        // 多重発火防止
        guard !isReconnecting else {
            print("[SKYWAY_RECONNECT] already reconnecting, skip (reason=\(reason))")
            return
        }
        guard !isSkyWayReady else {
            print("[SKYWAY_RECONNECT] already ready, skip (reason=\(reason))")
            return
        }
        isReconnecting = true
        // reconnectRetryCount はここでは0に戻さない（成功時 or 最終失敗時のみリセット）
        print("[SKYWAY_RECONNECT] start reason=\(reason) isSkyWayReady=\(isSkyWayReady) peerNil=\(peer == nil) retryCount=\(reconnectRetryCount) thread=\(Thread.isMainThread ? "MT" : "BG") cast_id=\(user_id)")

        // 既存接続をクリーンアップ（nil安全）
        isSkyWayReady = false
        isNewSDKReadyForApproval = false
        print("[SKYWAY_RECONNECT] cleanup: disconnect/destroy START thread=\(Thread.isMainThread ? "MT" : "BG")")
        dataConnection?.close()
        mediaConnection?.close()
        if let p = peer {
            if !p.isDisconnected {
                p.disconnect()
            }
            if !p.isDestroyed {
                p.destroy()
            }
            self.peer = nil
        }
        print("[SKYWAY_RECONNECT] cleanup: disconnect/destroy END, calling setup()")

        // setup() で peer を作り直す
        setup()
        attemptReconnectTimeout(reason: reason)
        print("[SKYWAY_RECONNECT] end: setup() called, timeout scheduled reason=\(reason) thread=\(Thread.isMainThread ? "MT" : "BG")")
    }

    /// 15秒タイムアウト監視。isSkyWayReady にならなければリトライ or 失敗通知。
    private func attemptReconnectTimeout(reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self else { return }
            guard self.isReconnecting else { return } // 既に成功 or 解除済み

            if self.isSkyWayReady {
                // OPEN到達済み → 何もしない（PEER_EVENT_OPENで処理済み）
                print("[SKYWAY_RECONNECT] already ready after timeout check, reason=\(reason)")
                return
            }

            self.reconnectRetryCount += 1
            if self.reconnectRetryCount < 2 {
                // 1回だけリトライ
                print("[SKYWAY_RECONNECT] timeout 15s, retrying once (retry=\(self.reconnectRetryCount)) reason=\(reason)")
                // クリーンアップして再度 setup
                if let p = self.peer {
                    if !p.isDisconnected { p.disconnect() }
                    if !p.isDestroyed { p.destroy() }
                    self.peer = nil
                }
                self.setup()
                self.attemptReconnectTimeout(reason: reason)
            } else {
                // 2回目も失敗 → 諦める
                print("[SKYWAY_RECONNECT] failed after retry reason=\(reason)")
                self.isReconnecting = false
                self.reconnectRetryCount = 0
                // pending approval をクリア
                if self.isPendingApproval {
                    self.isPendingApproval = false
                    self.pendingApprovalCompletion = nil
                }
                // ユーザーに通知（main thread）
                DispatchQueue.main.async {
                    UtilFunc.showAlert(message: "接続準備に失敗しました。通信状況を確認してください。", vc: self, sec: 5.0)
                }
            }
        }
    }
}

// MARK: skyway callbacks
extension WaitViewController{
    func setupPeerCallBacks(peer:SKWPeer){
        
        // MARK: PEER_EVENT_ERROR
        //待機がエラーとなった時に呼ばれる(???)
        peer.on(SKWPeerEventEnum.PEER_EVENT_ERROR, callback:{ (obj) -> Void in
            if let error = obj as? SKWPeerError{
                // NewSDKモード: 旧SDK失敗を sessionClose/reconnect/待機解除に波及させない
                if self.useNewSDK {
                    let _errCallId = self.pendingRequest?.callId ?? "-"
                    print("[SKYWAY_ERR] PEER_EVENT_ERROR IGNORED(old sdk failure in new sdk mode) thread=\(Thread.isMainThread ? "MT" : "BG") cast_id=\(self.user_id) callId=\(_errCallId) error=\(error)")
                    print("[CONNFAIL] waitState=\(self.waitState) isSkyWayReady=\(self.isSkyWayReady) isNewSDKReadyForApproval=\(self.isNewSDKReadyForApproval) isSessionClosing=\(self.isSessionClosing)")
                    UtilFunc.deleteCastLock(cast_id:self.user_id, user_id:self.user_id, type:1)
                    UtilFunc.deleteCastLock(cast_id:self.user_id, user_id:0, type:2)
                    return
                }

                let _errCallId2 = self.pendingRequest?.callId ?? "-"
                print("[SKYWAY_ERR] PEER_EVENT_ERROR thread=\(Thread.isMainThread ? "MT" : "BG") cast_id=\(self.user_id) callId=\(_errCallId2) isSkyWayReady→false error=\(error)")
                self.isSkyWayReady = false

                /******************************/
                //アンロック
                /******************************/
                //GET:user_id,type(1:待機状態への遷移ロック)
                UtilFunc.deleteCastLock(cast_id:self.user_id, user_id:self.user_id, type:1)
                //self.lock_flg = 0
                /******************************/
                //アンロック(ここまで)
                /******************************/

                //20200606追加
                //申請直後リスナーが落ちたときのストリーマーがロックされてしまう問題
                UtilFunc.deleteCastLock(cast_id:self.user_id, user_id:0, type:2)

                // 承認待ち中にエラーが発生した場合、再接続を試みる（多重発火防止・main thread）
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.isPendingApproval && !self.isReconnecting {
                        let callId = self.pendingRequest?.callId ?? "unknown"
                        print("[SKYWAY_ERR] error during pending approval, scheduling reconnect callId=\(callId)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            self?.setupSkyWayReconnect(reason: "peer_error_during_pending")
                        }
                    }
                }
            }
        })

        // MARK: PEER_EVENT_OPEN
        //待機が完了した時に呼ばれる
        peer.on(SKWPeerEventEnum.PEER_EVENT_OPEN,callback:{ (obj) -> Void in
            if let peerId = obj as? String{
                self.isSkyWayReady = true
                let _openCallId = self.pendingRequest?.callId ?? "-"
                print("[SKYWAY] PEER_EVENT_OPEN thread=\(Thread.isMainThread ? "MT" : "BG") cast_id=\(self.user_id) get_user_id=\(self.castWaitDialog.get_user_id) callId=\(_openCallId) peerId=\(peerId) isSkyWayReady→true")

                DispatchQueue.main.async {
                    //print("待機完了")
                    
                    //待機時のタイムスタンプ
                    //1:待機スタート 2:ライブ開始 3:ライブ後の待機 4：待機解除 5:運営タイムスタンプ（待機確認）
                    UtilFunc.addActionRireki(user_id: self.user_id, listener_id: 0, type: 1, value01:0, value02:0)

                    //通常の待機
                    //注意：下記は必要(予約リスナーの配信が始まる時に下記がないと、メッセージが表示され続けてしまう)
                    self.castWaitDialog.delMessageDo()
                    
                    //切り替え時のメッセージを表示
                    self.castWaitDialog.waitDialogView.isHidden = false//「１枠で配信中」のダイアログ
                    self.castWaitDialog.statusLbl.isHidden = false
                    
                    //待機中にする
                    self.appDelegate.reserveStatus = "1"
                    
                    self.listenerErrorFlg = 0
                    
                    //待機中はオブジェクトを全てhiddenに
                    //messageTextField.isHidden = true
                    if self.countDownLabel != nil {
                        self.countDownLabel.isHidden = true
                    }
                    
                    if self.userIconImageView != nil {
                        self.userIconImageView.isHidden = true
                    }
                    
                    if self.endCallButton != nil {
                        self.endCallButton.isHidden = true
                    }
                    
                    if self.oshiraseView != nil {
                        //お知らせのところ
                        self.oshiraseView.isHidden = true
                    }
                    
                    if self.starGetView != nil {
                        //右上のスター受信のところ
                        self.starGetView.isHidden = true
                    }

                    //待機が完了後、フォアグラウンドにある場合
                    self.castWaitDialog.requestDialogDo()

                    // 再接続完了フラグをクリア
                    self.isReconnecting = false
                    self.reconnectRetryCount = 0

                    // 承認待ちの場合: NewSDK も準備完了済みなら承認処理を再開
                    if self.isPendingApproval, let completion = self.pendingApprovalCompletion {
                        let callId = self.pendingRequest?.callId ?? "unknown"
                        if self.isNewSDKReadyForApproval {
                            print("[SKYWAY][APPROVAL] PEER_EVENT_OPEN: both ready, resuming approval callId=\(callId) isNewSDKReadyForApproval=true isSkyWayReady=\(self.isSkyWayReady)")
                            self.isPendingApproval = false
                            self.pendingApprovalCompletion = nil
                            completion()
                        } else {
                            print("[SKYWAY][APPROVAL] PEER_EVENT_OPEN: oldSDK ready, waiting for newSDK callId=\(callId) isNewSDKReadyForApproval=false")
                        }
                    }

                    /******************************/
                    //アンロック
                    /******************************/
                    //GET:user_id,type(1:待機状態への遷移ロック)
                    UtilFunc.deleteCastLock(cast_id:self.user_id, user_id:self.user_id, type:1)
                    /******************************/
                    //アンロック(ここまで)
                    /******************************/

                    //20200606追加
                    //申請直後リスナーが落ちたときのストリーマーがロックされてしまう問題
                    UtilFunc.deleteCastLock(cast_id:self.user_id, user_id:0, type:2)
                }
                print("your peerId: \(peerId)")
            }
        })
        
        //接続時に下記の２つが同時に呼ばれるか＞呼ばれる
        
        // MARK: PEER_EVENT_CONNECTION
        //通話コールされた時に呼ばれる
        peer.on(SKWPeerEventEnum.PEER_EVENT_CALL, callback: { (obj) -> Void in
            print("[PUBTRACE] file=WaitVC+CommonSkyway func=PEER_EVENT_CALL kind=media_answer useNewSDK=\(self.useNewSDK) peer=\(self.peer != nil) localStream=\(self.appDelegate.localStream != nil) BEFORE")
            print("[SKYWAY][CALL] PEER_EVENT_CALL: objType=\(type(of: obj))")
            // NewSDKモードでは旧SDKの connection.answer を実行しない
            // localStream が nil のまま answer() すると sender.cpp:78 (track assertion) でクラッシュする
            if self.useNewSDK {
                print("[DIAG][PEER_CALL] SKIP connection.answer: useNewSDK=true localStream=\(self.appDelegate.localStream != nil)")
                return
            }
            if let connection = obj as? SKWMediaConnection{
                //カメラなしのリスナーを考慮しコールバック処理はsetupDataConnectionCallbacksへ移動
                //20201120
                //ただし異常終了時のコールバックのみ使用する
                self.setupMediaConnectionCallbacks(mediaConnection: connection)
                self.mediaConnection = connection
                print("[PUBTRACE] file=WaitVC+CommonSkyway func=PEER_EVENT_CALL kind=connection.answer useNewSDK=\(self.useNewSDK) localStream=\(self.appDelegate.localStream != nil) CALLING")
                connection.answer(self.appDelegate.localStream)
                
                /*
                //20201118 下記リフレッシュボタンを押した時に通したいが一旦廃止のためコメントアウト
                //リフレッシュボタンを廃止
                if(self.isReconnect == true) {

                    //（一時的異常状態に）初期化する
                    //self.listenerErrorFlg = 0
                    //正常状態(人的操作によるもの)にする
                    self.listenerErrorFlg = 1
                    
                    //正常状態に初期化する
                    self.listenerStatus = 0//重要
                
                    self.castSelectedDialog.isHidden = true

                    DispatchQueue.main.async {
                        //念の為、ここでも非表示
                        self.castWaitDialog.topInfoLabel.isHidden = true
                    
                        // タイムアウトのタイマーを無効にする
                        self.castWaitDialog.requestTimer.invalidate()

                        //接続状態(会話開始状態)へ
                        //self.removeFromSuperview()
                        self.castWaitDialog.waitDialogView.isHidden = true
                        self.castWaitDialog.statusLbl.isHidden = true
                    
                        self.castWaitDialog.allCoverMessage.isHidden = true
                        self.castWaitDialog.allCoverRequest.isHidden = true
                        self.castWaitDialog.topInfoLabel.isHidden = true

                        self.isReconnect = false
                    }
                }
                */
            }
        })
        
        // MARK: PEER_EVENT_CONNECTION
        //チャットコールされた時に呼ばれる
        peer.on(SKWPeerEventEnum.PEER_EVENT_CONNECTION, callback: { (obj) -> Void in
            print("[SKYWAY][CALL] PEER_EVENT_CONNECTION: objType=\(type(of: obj))")
            if let connection = obj as? SKWDataConnection{
                self.dataConnection = connection
                self.setupDataConnectionCallbacks(dataConnection: connection)
            }
        })
    }

    /***************************/
    /***************************/
    // AVAudioSession をスピーカー優先で設定（イヤホン/Bluetooth接続時はそちらを優先）
    func configureAudioSessionForSpeaker() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .videoChat,
                options: [
                    .defaultToSpeaker,
                    .allowBluetooth,
                    .allowBluetoothA2DP
                ]
            )
            try session.setActive(true)
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
            let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
            print("[AudioSession] configured (Cast)")
            print("[AudioSession] inputs: \(inputs)")
            print("[AudioSession] outputs: \(outputs)")
        } catch {
            print("[AudioSession] configure failed (Cast): \(error)")
        }
    }

    // receiver出力時のみスピーカーへ切り替え（イヤホン/Bluetooth接続時はスキップ）
    func forceSpeakerOnlyWhenNoExternalRoute(reason: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs

        let hasExternalOutput = outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                return true
            default:
                return false
            }
        }

        let hasReceiver = outputs.contains { $0.portType == .builtInReceiver }

        print("[AudioSession] forceSpeaker check reason=\(reason)")
        print("[AudioSession] current outputs: \(outputs.map { "\($0.portType.rawValue):\($0.portName)" })")

        guard !hasExternalOutput else {
            print("[AudioSession] skip force speaker: external output exists")
            return
        }

        guard hasReceiver else {
            print("[AudioSession] skip force speaker: receiver is not current output")
            return
        }

        do {
            try session.overrideOutputAudioPort(.speaker)
            print("[AudioSession] forced speaker output")
        } catch {
            print("[AudioSession] force speaker failed: \(error)")
        }
    }

    // 電話による割り込みと、オーディオルートの変化を監視します
    func addAudioSessionObservers() {
        //UtilLog.printf(str:"オーディオルートの設定（ストリーマー側）")

        //let center = NotificationCenter.default
        self.center.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        self.center.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        self.center.addObserver(self, selector: #selector(audioSessionRouteChanged(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        self.center.addObserver(self, selector: #selector(audioSessionRouteChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    // Audio Session Route Change : ルートが変化した(ヘッドフォンが抜き差しされた)
    @objc func audioSessionRouteChanged(_ notification: Notification) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
        print("[AudioSession] route changed (Cast)")
        print("[AudioSession] inputs: \(inputs)")
        print("[AudioSession] outputs: \(outputs)")

        //ヘッドフォン端子に何らかの変化があった場合
        //停止して1秒後に再始動を行う
        self.appDelegate.localStream?.setEnableAudioTrack(0, enable: false)
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) {
            // headphone
            self.appDelegate.localStream?.setEnableAudioTrack(0, enable: true)
            self.forceSpeakerOnlyWhenNoExternalRoute(reason: "audioSessionRouteChanged+1s")
        }
    }

    /*
    // イヤホン（ヘッドホン出力）の場合
    func remoteAudioDefault() {
        self.appDelegate.localStream?.setEnableAudioTrack(0, enable: false)
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) {
          // headphone
          do {
              try AVAudioSession.sharedInstance().setActive(true)
              try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playAndRecord)
              try AVAudioSession.sharedInstance().overrideOutputAudioPort(AVAudioSession.PortOverride.none)
              self.appDelegate.localStream?.setEnableAudioTrack(0, enable: true)
              UtilLog.printf(str:"イヤホン（ヘッドホン出力）")
          } catch {
            print("AVAudioSessionCategoryPlayAndRecord error")
          }
        }
    }
    
    // 内臓スピーカー出力の場合
    func remoteAudioSpeaker() {
        self.appDelegate.localStream?.setEnableAudioTrack(0, enable: false)
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) {
          // speaker
          do {
              let audioSession = AVAudioSession.sharedInstance()
              try audioSession.setCategory(AVAudioSession.Category.playAndRecord)
              try audioSession.setMode(AVAudioSession.Mode.videoChat)
              try audioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.speaker)
              try audioSession.setActive(true)
              self.appDelegate.localStream?.setEnableAudioTrack(0, enable: true)
              UtilLog.printf(str:"remoteAudioSpeaker:内臓スピーカー出力")
          } catch {
            print("AVAudioSessionCategoryPlayAndRecord error")
          }
        }
    }
     */
    /***************************/
    /***************************/
    
    //通話のコールバック
    func setupMediaConnectionCallbacks(mediaConnection:SKWMediaConnection){

        // MARK: MEDIACONNECTION_EVENT_STREAM
        //相手につながった時に呼ばれる(映像が両方で有効の時にしか通らない)
        mediaConnection.on(SKWMediaConnectionEventEnum.MEDIACONNECTION_EVENT_STREAM, callback: { (obj) -> Void in
            //UtilLog.printf(str:"通話のコールバック")
            self.addAudioSessionObservers()
        })
 
        // MARK: MEDIACONNECTION_EVENT_CLOSE
        //相手と切断された時に呼ばれる＞呼ばれる(チャットの方も呼ばれる)
        //ここではリスナーの異常終了の場合のみ処理を行う
        mediaConnection.on(SKWMediaConnectionEventEnum.MEDIACONNECTION_EVENT_CLOSE, callback: { (obj) -> Void in
            
            if let _ = obj as? SKWMediaConnection{

                DispatchQueue.main.async {
                    if(self.listenerErrorFlg == 0){
                        self.listenerStatus = 1//重要
                        //end of 異常終了の場合のみここで処理終わり
                    }
                }
            }
        })
    }

    //チャットのコールバック
    func setupDataConnectionCallbacks(dataConnection:SKWDataConnection){
        // MARK: DATACONNECTION_EVENT_OPEN
        //相手につながった時に呼ばれる＞呼ばれる
        dataConnection.on(SKWDataConnectionEventEnum.DATACONNECTION_EVENT_OPEN, callback: { (obj) -> Void in
            print("[SKYWAY][CALL] DATACONNECTION_EVENT_OPEN: objType=\(type(of: obj))")
            //20201118 add
            self.startConnection()
            
            //（一時的異常状態に）初期化する
            self.listenerErrorFlg = 0
            //正常状態に初期化する
            self.listenerStatus = 0//重要
            
            if (obj as? SKWDataConnection) != nil{
                //待機中はオブジェクトを全てhiddenに>接続されると表示
                //messageTextField.isHidden = true
                self.countDownLabel.isHidden = false
                self.userIconImageView.isHidden = false
                self.endCallButton.isHidden = false
                
                //ダイアログ関連を非表示にしておく
                self.castWaitDialog.allCoverMessage.isHidden = true
                self.castWaitDialog.re_connect_label.isHidden = true
                self.castWaitDialog.topInfoLabel.isHidden = true
                
                if(self.appDelegate.reserveStatus == "1"){
                    //配信中の状態へ(待機状態から接続状態になったときのみ、下記を実行)
                    UtilFunc.loginDo(user_id:self.user_id, status:2, live_user_id: self.appDelegate.live_target_user_id, reserve_flg:Int(self.appDelegate.reserveFlg)!, max_reserve_count:Int(self.appDelegate.reserveMaxCount)!, password:"0")
                    
                    //通話状態へ
                    self.appDelegate.reserveStatus = "2"

                    //絆レベル課金ポイントのボーナス比率など相手との情報を取得
                    UtilFunc.getConnectInfo(my_user_id:self.user_id, target_user_id:self.appDelegate.live_target_user_id)

                    //復帰時にここを通るか？
                    //print(self.appDelegate.reserveStatus)
                    self.countDownLabel.isHidden = false
                    self.userIconImageView.isHidden = false
                    self.endCallButton.isHidden = false
                    
                    //お知らせのところ
                    self.oshiraseView.isHidden = true
                    //右上のスター受信のところ
                    self.starGetView.isHidden = true
                    
                    //ユーザーアイコンにアクションの設定
                    self.userIconImageView.isUserInteractionEnabled = true
                    self.userIconImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.userIconImageViewTapped(_:))))

                    //ターゲットユーザーの情報を取得する
                    //情報取得時にユーザーアイコンに画像を設定する
                    self.getTargetInfo(target_id : self.appDelegate.live_target_user_id)
                    
                    //ターゲットユーザーのダイアログを作成しておく
                    self.userInfoDialog = UINib(nibName: "OnLiveUserInfo", bundle: nil).instantiate(withOwner: self,options: nil)[0] as! OnLiveUserInfo
                    //最初は非表示(リスナー情報ダイアログ)
                    //画面サイズに合わせる
                    self.userInfoDialog.frame = self.view.frame
                    // 貼り付ける
                    self.view.addSubview(self.userInfoDialog)
                    self.userInfoDialog.isHidden = true

                    //もしタイマーが実行中だったらスタートしない
                    if(self.timerLive.isValid == true){
                        //何も処理しない
                    }else{
                        //配信時間のクリア
                        self.appDelegate.count = 0
                        
                        //タイマーをスタート
                        self.timerLive = Timer.scheduledTimer(timeInterval:1.0,
                                                              target: self,
                                                              selector: #selector(self.timerInterruptLive(_:)),
                                                              userInfo: nil,
                                                              repeats: true)
                    }
                    
                    //重要(リアルタイムデータベースを使用)
                    self.conditionRef = self.rootRef.child(Util.INIT_FIREBASE + "/"
                        + String(self.user_id) + "/" + String(self.appDelegate.live_target_user_id))

                    //イベント監視
                    self.handle = self.conditionRef.observe(.value, with: { snap in
                        print("🔥 OBSERVER A START 🔥 conditionRef path=\(self.conditionRef.url) snap=\(snap)")
                        //print("ノードの値が変わりました！: \((snap.value as AnyObject).description)")
                        
                        if(snap.exists() == false){
                            //UtilLog.printf(str:"すでにデータがない(キャスト側)")
                            return
                        }
                        
                        //let dict = snap.value as! [String : AnyObject]
                        guard let outer = snap.value as? [String: Any],
                              let inner = outer.values.first as? [String: Any] else {
                            print("[WAIT] conditionRef: snap.value parse error, value=\(String(describing: snap.value))")
                            return
                        }
                        let dict = inner as NSDictionary

                        //status_listener = 5:異常終了からの復帰(リスナー側)
                        //０：サシライブ中でない、１：待機が完了、２：サシライブ中、３：バツボタンで終了、
                        //４：コインがなく延長ができなくなった時、５：リスナーが異常終了した時(未使用)、
                        //６：リスナーが異常終了から復帰した時、7：復帰完了（一時的）＞リスナー側は現時間を反映し「２：サシライブ中」に状態変更する
                        print("🚨 STATUS PARSE START 🚨")
                        guard let rawStatusListener = inner["status_listener"],
                              let statusNumber = rawStatusListener as? NSNumber else {
                            print("[WAIT] conditionRef: status_listener missing or not NSNumber, raw=\(inner["status_listener"] as Any)")
                            return
                        }
                        let status_listener = statusNumber.intValue
                        
                        print("[WAITREQ][CHECK] useNewSDK=\(self.useNewSDK) status_listener=\(status_listener)")
                        print("🔥🔥🔥 IF CHECK 🔥🔥🔥 useNewSDK=\(self.useNewSDK) status_listener=\(status_listener)")
                        if self.useNewSDK && status_listener == 3 {
                            print("[WAITREQ][DEBUG] entering LEAVE branch")
                            print("🔥🔥🔥 LEAVE BRANCH 🔥🔥🔥")
                            // status_listener == 3: live ended by listener.
                            // commonWaitDo handles cleanup + leaveRoomIfNeeded; shouldRestart=false skips new session.
                            DispatchQueue.main.async {
                                self.commonWaitDo(status: 1, shouldRestart: false)
                                // 前回のリクエストノードを削除して次のリスナー申請を受け付けられるようにする
                                self.rootRef
                                    .child(Util.INIT_FIREBASE + "/" + String(self.user_id) + "/" + String(self.appDelegate.live_target_user_id))
                                    .removeValue()
                            }
                            return
                        }

                        if(status_listener == 3 || status_listener == 4){
                            //リスナーがバツボタンを押して終わった(またはリスナーのコインがなくなった場合)
                            //self.commonWaitDo()
                            self.commonWaitDo(status:1)
                        }else if(status_listener == 6){
                            //この時点でリスナーとの接続が復活している
                            if(self.appDelegate.count >= self.appDelegate.init_seconds - 10){
                                //ここは通常処理されないが、念のため
                                //50秒(10秒前は復帰できない)を経過していたら待機状態へ
                                if(self.appDelegate.reserveStatus == "5"){
                                    //予約がある時
                                    self.commonWaitDo(status:8)
                                }else{
                                    self.commonWaitDo(status:1)
                                }

                            }else{
                                //現時点の時間をセットし、リスナーの状態を「復帰完了」にする（リスナーと合わせる）
                                let data = ["live_time": self.appDelegate.count, "status_listener": 7]
                                self.conditionRef.updateChildValues(data)
                                
                                //復帰のメッセージ関連
                                self.castWaitDialog.showMessageDo(message:"リスナーとの通信が回復しました。\nサシライブを続けてください。", font: 15)

                                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                    // 5.0秒後に実行したい処理
                                    self.castWaitDialog.delMessageDo()
                                }
                            }
                            
                            return
                        }

                        //延長時のスターをゲット
                        let cast_add_star = (dict["cast_add_star"] as? Int) ?? 0
                        let cast_add_point = (dict["cast_add_point"] as? Int) ?? 0
                        if(cast_add_star > 0 || cast_add_point > 0){
                            //0に戻す
                            let data = ["cast_add_star": 0, "cast_add_point": 0]
                            self.conditionRef.updateChildValues(data)

                            //配信経験値/スターの加算・配信レベルの計算・アプリ内の値を更新・配信ポイント履歴に保存
                            //type:1:配信による経験値 2:プレゼントによる経験値3:延長による経験値99:没収したスター
                            self.getLivePoint(type:3,
                                              cast_id:self.user_id,
                                              user_id:self.appDelegate.live_target_user_id,
                                              point_num:cast_add_point,
                                              star_num:cast_add_star,
                                              live_count:0,
                                              seconds:Util.INIT_EX_UNIT_SECONDS,
                                              re_star:0,
                                              action_flg:1)
                            
                            return
                        }
                        
                        //プレゼントゲット
                        let present_star = (dict["present_star"] as? Int) ?? 0
                        let present_point = (dict["present_point"] as? Int) ?? 0
                        if(present_star > 0 || present_point > 0){
                            //0に戻す
                            let data = ["present_star": 0, "present_point": 0]
                            self.conditionRef.updateChildValues(data)
                            //配信経験値/スターの加算・配信レベルの計算・アプリ内の値を更新・配信ポイント履歴に保存
                            //type:1:配信による経験値 2:プレゼントによる経験値3:延長による経験値99:没収したスター
                            self.getLivePoint(type:2,
                                              cast_id:self.user_id,
                                              user_id:self.appDelegate.live_target_user_id,
                                              point_num:present_point,
                                              star_num:present_star,
                                              live_count:0,
                                              seconds:0,
                                              re_star:0,
                                              action_flg:1)
                            
                            return
                        }
                        
                        //機能を廃止
                        /*
                        //スクショのリクエスト
                        let request_screenshot_flg = dict["request_screenshot_flg"] as! Int
                        if(request_screenshot_flg == 1){
                            //スクリーンショットのリクエスト
                            //0に戻す
                            let data = ["request_screenshot_flg": 0]
                            self.conditionRef.updateChildValues(data)
                            
                            //重要
                            //お知らせ表示
                            self.oshiraseView.isHidden = false
                            let strLiveInfoTemp = UtilFunc.strMin(str:self.appDelegate.live_target_user_name, num:Util.NAME_MOJI_COUNT_SMALL) + Util.LIVE_RIREKI_STR01
                            self.oshiraseLbl.text = "・" + strLiveInfoTemp
                            self.view.bringSubviewToFront(self.oshiraseView)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                // 5.0秒後に実行したい処理
                                //非表示
                                self.oshiraseView.isHidden = true
                            }
                            
                            //メッセージテーブルのリロード
                            self.castWaitDialog.messageTableView.reloadData()
                            
                            //配信情報の保存＋リアルタイム更新
                            //type=1:まつさんからスクショリクエストがありました
                            UtilFunc.saveLiveRireki(cast_id:self.user_id, type:1, notes:strLiveInfoTemp, listener_id:self.appDelegate.live_target_user_id)
                            
                            return
                            
                        }else if(request_screenshot_flg == 4){
                            let cast_send_screenshot = dict["request_screenshot_name"] as! String
                            if(cast_send_screenshot == "0" || cast_send_screenshot == ""){
                                //スクリーンショットのリクエスト(ユーザーが受け取った時)
                                //0に戻す
                                let data = ["request_screenshot_flg": 0]
                                self.conditionRef.updateChildValues(data)
                                
                                //スクショ中のカメラ画面は一旦閉じて、ダイアログ(スターの加算のダイアログ)を数秒表示
                                //self.onCameraClose()
                                
                                //配信経験値/スターの加算・配信レベルの計算・アプリ内の値を更新・配信ポイント履歴に保存
                                //1:配信による経験値 2:プレゼントによる経験値3:延長による経験値 4:予約キャンセル(スター追加のみ)5スクショによるスター獲得99:スター没収
                                self.getLivePoint(type:5,
                                                  cast_id:self.user_id,
                                                  user_id:self.appDelegate.live_target_user_id,
                                                  point_num:0,
                                                  star_num:Util.SCREENSHOT_GET_STAR,
                                                  live_count:0,
                                                  seconds:0,
                                                  re_star:0,
                                                  action_flg:1)

                                //お知らせ表示
                                //2:まつさんにスクショを送りました
                                self.oshiraseView.isHidden = false
                                let strLiveInfoTemp = UtilFunc.strMin(str:self.appDelegate.live_target_user_name, num:Util.NAME_MOJI_COUNT_SMALL) + Util.LIVE_RIREKI_STR02
                                self.oshiraseLbl.text = "・" + strLiveInfoTemp
                                self.view.bringSubviewToFront(self.oshiraseView)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                    // 5.0秒後に実行したい処理
                                    //非表示
                                    self.oshiraseView.isHidden = true
                                }
                                
                                //メッセージテーブルのリロード(不要)
                                //self.messageTableView.reloadData()
                                
                                //配信情報の保存＋リアルタイム更新
                                UtilFunc.saveLiveRireki(cast_id:self.user_id, type:2, notes:strLiveInfoTemp, listener_id:self.appDelegate.live_target_user_id)
                            }
                            return
                        }*/
                    })
                }
            }//end of if reserveStatus == 1
        })

        // MARK: DATACONNECTION_EVENT_DATA
        //何かメッセージがきた時に呼ばれる
        print("[CHAT][RECV] observer started peer=\(dataConnection.peer)")
        dataConnection.on(SKWDataConnectionEventEnum.DATACONNECTION_EVENT_DATA, callback: { (obj) -> Void in
            print("[CHAT][RECV] DATACONNECTION_EVENT_DATA fired type=\(type(of: obj))")
            guard let strValue = obj as? String else {
                print("[WAIT] DATACONNECTION_EVENT_DATA: obj is not String, type=\(type(of: obj)), value=\(String(describing: obj))")
                return
            }
            print("[CHAT][RECV] received peer=\(dataConnection.peer) len=\(strValue.count)")
            
            if(strValue.contains("画面リフレッシュ"))
            {
                
                self.isReconnect = true
                /***************************/
                //ラベル作成
                /***************************/
                self.castSelectedDialog.infoLbl.frame = CGRect(x:0, y:0, width:UIScreen.main.bounds.width, height:0)
                // テキストを中央寄せ
                self.castSelectedDialog.infoLbl.attributedText = UtilFunc.getInsertIconString(string: "画面をリフレッシュしています。", iconImage: UIImage(), iconSize: self.iconSize, lineHeight: 1.5)
                //self.infoLbl.textAlignment = NSTextAlignment.center
                self.castSelectedDialog.infoLbl.font = UIFont.boldSystemFont(ofSize: 15)
                self.castSelectedDialog.infoLbl.sizeToFit()
                self.castSelectedDialog.infoLbl.center = self.castSelectedDialog.center
                //最前面へ
                self.castSelectedDialog.infoLbl.isHidden = false
                self.castSelectedDialog.bringSubviewToFront(self.castSelectedDialog.infoLbl)
                /***************************/
                //ラベル作成(ここまで)
                /***************************/
                
                self.castSelectedDialog.closeBtn.isHidden = true

                self.castSelectedDialog.isHidden = false
                //self.view.bringSubviewToFront(self.castSelectedDialog)
                self.appDelegate.window!.bringSubviewToFront(self.castSelectedDialog)
                return
            }
            print("get data: \(strValue)")
            let message = Message(sender: Message.SenderType.get, text: strValue)
            //self.messages.insert(message, at: 0)
            self.messages.insert(message, at: self.messages.count)//下から上に投稿を流す場合
            
            //MediaConnectionViewController.messageTableView.reloadData()
            self.castWaitDialog.messageTableView.reloadData()
            
            if(strValue.hasPrefix("$$$_nocoin_")) {
                //リスナーがコイン不足のとき（強制的にチャット領域を表示）
                self.castWaitDialog.messageTableView.isHidden = false//タイムラインを表示
                self.liveTimelineFlg = 1
                
                //タイムラインアイコンを選択中のアイコンに変更する
                self.timelineBtn.image = UIImage(named: "lm_ico_on")!.withRenderingMode(UIImage.RenderingMode.alwaysOriginal)
            }
        })
        
        // MARK: DATACONNECTION_EVENT_CLOSE
        //相手と切断された時に呼ばれる＞呼ばれる
        dataConnection.on(SKWDataConnectionEventEnum.DATACONNECTION_EVENT_CLOSE, callback: { (obj) -> Void in
            //print("close data connection")

            //20201118 add
            if let _ = obj as? SKWDataConnection{
                DispatchQueue.main.async {
                    if(self.listenerErrorFlg == 0){
                        self.listenerStatus = 1//重要
                        //end of 異常終了の場合
                    }else{
                        //正常に終了した場合
                        //リスナー異常終了フラグの初期化>接続時のみゼロにする
                        self.refreshBtn.isHidden = true
                        self.listenerErrorFlg = 0
                    }
                }
            }
        })
    }
    
    func send(text: String) {
        //$$$から始まる文字列はスタンプとする
        if(text.contains("画面リフレッシュ"))
        {
            isReconnect = true
            if useNewSDK {
                SkywayManager.sharedManager().sendData(text: text)
            } else {
                self.dataConnection?.send(text as NSObject)
            }
        }else if (!text.hasPrefix("$$$") && text != "") {
            print("送信した文字列")
            print(text)
            if useNewSDK {
                SkywayManager.sharedManager().sendData(text: text)
            } else {
                self.dataConnection?.send(text as NSObject)
            }
            let message = Message(sender: Message.SenderType.send, text: text)
            print(message.text as Any)
            //self.messages.insert(message, at: 0)
            self.messages.insert(message, at: self.messages.count)//下から上に投稿を流す場合
            
            //履歴保存
            UtilFunc.saveChatRireki(type:1, from_user_id:self.user_id, to_user_id:self.appDelegate.live_target_user_id, present_id:0, chat_text:text, status:1)
        }
    }
    
    func sendStamp(text: String) {
        //$$$から始まる文字列はスタンプとする
        if text.hasPrefix("$$$") {
            //print("送信した文字列")
            //print(text)
            
            var send_text = ""
            if(text == "$$$_screenshot_request"){
                //スクショリクエストの送信
                send_text = "スクショをリクエストしました。"
            }else if(text.hasPrefix("$$$_stamp_")){
                //スタンプの送信(そのままの文字列を入れる。画像用のCellを使用するため)
                send_text = text
            }
            if useNewSDK {
                SkywayManager.sharedManager().sendData(text: send_text)
            } else {
                self.dataConnection?.send(send_text as NSObject)
            }
            let message = Message(sender: Message.SenderType.send, text: send_text)
            self.messages.insert(message, at: self.messages.count)//下から上に投稿を流す場合

            //履歴保存
            UtilFunc.saveChatRireki(type:2, from_user_id:self.user_id, to_user_id:self.appDelegate.live_target_user_id, present_id:0, chat_text:send_text, status:1)
        }
    }
}

// MARK: - Point Sync
extension WaitViewController {

    /// livePointLbl を currentPoint の値で更新する（メインスレッド保証）
    func updatePointLabel() {
        print("[DIAG][UI] updatePointLabel called currentPoint=\(self.currentPoint) thread=\(Thread.isMainThread ? "MT" : "BG")")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("[DIAG][UI] APPLY livePointLbl exists=\(self.livePointLbl != nil)")
            if self.livePointLbl == nil { return }
            let text = String(UtilFunc.numFormatter(num: self.currentPoint)) + " pt"
            self.livePointLbl.text = text
            self.livePointLbl.adjustsFontSizeToFitWidth = true
            self.livePointLbl.minimumScaleFactor = 0.3
        }
    }

    /// サーバーからポイントを取得し currentPoint → livePointLbl を更新する
    /// 多重呼び出し時は最新の呼び出しのみ UI に反映する（token 方式）
    func syncLivePoint() {
        print("[DIAG][SYNC] ENTER user_id=\(self.user_id) thread=\(Thread.isMainThread ? "MT" : "BG")")
        let token = UUID()
        self.syncPointToken = token
        print("[DIAG][SYNC_POINT] START user_id=\(self.user_id) token=\(token) thread=\(Thread.isMainThread ? "MT" : "BG")")

        UtilFunc.setMyInfo { [weak self] in
            guard let self = self else {
                print("[DIAG][SYNC_POINT] self deallocated in completion, token=\(token)")
                return
            }
            // トークンが一致しなければ、より新しい呼び出しがあるので破棄
            guard self.syncPointToken == token else {
                print("[DIAG][SYNC_POINT] STALE token=\(token) current=\(self.syncPointToken), skip")
                return
            }
            let pt = UserDefaults.standard.integer(forKey: "myLivePoint")
            let oldPt = self.currentPoint
            self.currentPoint = pt
            print("[DIAG][SYNC_POINT] SUCCESS oldPt=\(oldPt) newPt=\(pt) token=\(token) thread=\(Thread.isMainThread ? "MT" : "BG")")
            self.updatePointLabel()
            print("[DIAG][SYNC] EXIT currentPoint=\(self.currentPoint)")
        }
    }
}

// MARK: - New SDK Entry Points (Phase1)
extension WaitViewController {

    func startWaitingUsingNewSDK() {
        print("[NewSDK][MVP] startWaitingUsingNewSDK ENTER waitState=\(waitState) isSessionClosing=\(isSessionClosing) isLiveConnectionStarted=\(isLiveConnectionStarted) thread=\(Thread.isMainThread ? "MT" : "BG")")

        // 配信ポイント(累計)の初期化（旧SDKでは setWait() 内で行っていた処理）
        if self.livePointLbl != nil {
            if UserDefaults.standard.object(forKey: "myLivePoint") != nil {
                let myLivePoint = UserDefaults.standard.integer(forKey: "myLivePoint")
                self.livePointLbl.text = String(UtilFunc.numFormatter(num: myLivePoint)) + " pt"
            } else {
                self.livePointLbl.text = "- pt"
            }
            self.livePointLbl.adjustsFontSizeToFitWidth = true
            self.livePointLbl.minimumScaleFactor = 0.3
        }

        // 新しい待機サイクルのためフラグリセット
        isSessionClosing = false
        sessionCloseCompletedOnce = false
        isCancelWaitFlow = false
        sessionCloseTimeoutTask?.cancel()
        sessionCloseTimeoutTask = nil

        // 再配信安定化のため全フラグリセット
        isLiveConnectionStarted = false
        isNewSDKReadyForApproval = false
        isPendingApproval = false
        pendingApprovalCompletion = nil
        pendingRequest = nil
        isReconnecting = false
        reconnectRetryCount = 0

        // Firebase の前回配信データをリセット（status=99, room_name 等が残留する問題の防止）
        self.rootRef.child(Util.INIT_FIREBASE + "/" + String(self.user_id)).removeValue()
        self.castWaitDialog.status = 0
        self.appDelegate.live_target_user_name = ""
        self.appDelegate.live_target_user_id = 0
        print("[NewSDK][MVP] startWaitingUsingNewSDK: Firebase userrequest/\(self.user_id) removed")

        // サーバーに待機状態を通知（旧SDKでは setWait() 内の loginDo() で行っていた処理）
        // これがないとリスナー側で reserve_flg/login_status が更新されず「予約申請をすることができません」になる
        print("[DIAG][LOGIN_DO] START user_id=\(self.user_id) reserveFlg=\(self.appDelegate.reserveFlg) maxReserve=\(self.appDelegate.reserveMaxCount) thread=\(Thread.isMainThread ? "MT" : "BG")")
        UtilFunc.loginDo(user_id: self.user_id, status: 1, live_user_id: 0, reserve_flg: Int(self.appDelegate.reserveFlg)!, max_reserve_count: Int(self.appDelegate.reserveMaxCount)!, password: "0")
        print("[DIAG][LOGIN_DO] END (call returned)")

        // 配信ポイント(累計)をサーバーから同期（旧SDKでは setWait() 内で直接表示していた処理）
        print("[DIAG][SYNC_CALL] from=startWaitingUsingNewSDK")
        self.syncLivePoint()

        // Firebase conditionRef observer を SkyWay 接続前に設定
        // リスナーのリクエストは SkyWay 接続前に Firebase に書き込まれるため、
        // ここで observer を登録しないと初回待機で取りこぼす
        // 重複防止: 既存の handle を解除してから再登録
        self.conditionRef.removeObserver(withHandle: self.handle)
        self.conditionRef = self.rootRef.child(Util.INIT_FIREBASE + "/"
            + String(self.user_id))
        print("[NewSDK] startWaitingUsingNewSDK: conditionRef observer setup path=\(self.conditionRef.url)")
        self.handle = self.conditionRef.observe(.value, with: { [weak self] snap in
            guard let self = self else { return }
            print("🔥 OBSERVER A START 🔥 conditionRef path=\(self.conditionRef.url) waitState=\(self.waitState) live_target=\(self.appDelegate.live_target_user_id) snap.exists=\(snap.exists())")

            if snap.exists() == false {
                return
            }

            guard let outer = snap.value as? [String: Any],
                  let inner = outer.values.first as? [String: Any] else {
                print("[WAIT] conditionRef: snap.value parse error, value=\(String(describing: snap.value))")
                return
            }
            let dict = inner as NSDictionary

            print("🚨 STATUS PARSE START 🚨")
            guard let rawStatusListener = inner["status_listener"],
                  let statusNumber = rawStatusListener as? NSNumber else {
                print("[WAIT] conditionRef: status_listener missing or not NSNumber, raw=\(inner["status_listener"] as Any)")
                return
            }
            let status_listener = statusNumber.intValue

            print("[WAITREQ][CHECK] useNewSDK=\(self.useNewSDK) status_listener=\(status_listener)")
            if self.useNewSDK && status_listener == 3 {
                DispatchQueue.main.async {
                    self.commonWaitDo(status: 1, shouldRestart: false)
                    self.rootRef
                        .child(Util.INIT_FIREBASE + "/" + String(self.user_id) + "/" + String(self.appDelegate.live_target_user_id))
                        .removeValue()
                }
                return
            }

            if status_listener == 3 || status_listener == 4 {
                self.commonWaitDo(status: 1)
            } else if status_listener == 6 {
                if self.appDelegate.count >= self.appDelegate.init_seconds - 10 {
                    if self.appDelegate.reserveStatus == "5" {
                        self.commonWaitDo(status: 8)
                    } else {
                        self.commonWaitDo(status: 1)
                    }
                } else {
                    let data: [String: Any] = ["live_time": self.appDelegate.count, "status_listener": 7]
                    self.conditionRef.updateChildValues(data)
                    self.castWaitDialog.showMessageDo(message: "リスナーとの通信が回復しました。\nサシライブを続けてください。", font: 15)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        self.castWaitDialog.delMessageDo()
                    }
                }
                return
            }

            // 延長時のスターをゲット
            let cast_add_star = (dict["cast_add_star"] as? Int) ?? 0
            let cast_add_point = (dict["cast_add_point"] as? Int) ?? 0
            if cast_add_star > 0 || cast_add_point > 0 {
                let data: [String: Any] = ["cast_add_star": 0, "cast_add_point": 0]
                self.conditionRef.updateChildValues(data)
                self.getLivePoint(type: 3,
                                 cast_id: self.user_id,
                                 user_id: self.appDelegate.live_target_user_id,
                                 point_num: cast_add_point,
                                 star_num: cast_add_star,
                                 live_count: 0,
                                 seconds: Util.INIT_EX_UNIT_SECONDS,
                                 re_star: 0,
                                 action_flg: 1)
                return
            }

            // プレゼントゲット
            let present_star = (dict["present_star"] as? Int) ?? 0
            let present_point = (dict["present_point"] as? Int) ?? 0
            if present_star > 0 || present_point > 0 {
                let data: [String: Any] = ["present_star": 0, "present_point": 0]
                self.conditionRef.updateChildValues(data)
                self.getLivePoint(type: 2,
                                 cast_id: self.user_id,
                                 user_id: self.appDelegate.live_target_user_id,
                                 point_num: present_point,
                                 star_num: present_star,
                                 live_count: 0,
                                 seconds: 0,
                                 re_star: 0,
                                 action_flg: 1)
                return
            }
        })

        // 待機開始準備中: 配信UIを非表示にし操作を無効化
        // sessionStart → connectSucces() で .waiting になる
        Task { @MainActor in
            self.setWaitState(.starting)
        }
        // NewSDK チャット受信登録
        SkywayManager.sharedManager().onChatReceived = { [weak self] text in
            DispatchQueue.main.async {
                self?.handleIncomingChat(text: text)
            }
        }
        SkywayManager.sharedManager().onChatReceivedMeta = { [weak self] _, meta in
            guard let self = self else { return }
            if let v = meta["user_id"] as? Int        { self.strUserId    = String(v) }
            if let v = meta["user_photo_flg"] as? Int { self.strPhotoFlg  = String(v) }
            if let v = meta["user_photo_name"] as? String { self.strPhotoName = v }
            if let v = meta["user_name"] as? String, !v.isEmpty { self.strUserName = v }
            print("[CHAT][NEWSDK][META] userId=\(self.strUserId) photoFlg=\(self.strPhotoFlg) photoName=\(self.strPhotoName)")
        }
        print("[CHAT][NEWSDK] onChatReceived registered in startWaitingUsingNewSDK")
        print("[NewSDK][MVP] calling SkywayManager.setWaitLocal")
        SkywayManager.sharedManager().setWaitLocal(localView: self.localStreamView, delegate: self)
        print("[NewSDK][MVP] calling SkywayManager.setRemoteView")
        SkywayManager.sharedManager().setRemoteView(remoteView: self.remoteStreamView)
        print("[NewSDK][MVP] calling SkywayManager.sessionStart")
        SkywayManager.sharedManager().sessionStart(delegate: self)
    }

    func closeMediaUsingNewSDK() {
        // TODO (Phase2-2): SkywayManager 経由でメディア切断へ接続する
        print("[NewSDK][Phase1] closeMediaUsingNewSDK called")
    }

    func sessionCloseUsingNewSDK() {
        // TODO (Phase2-2): SkywayManager 経由でセッション終了へ接続する
        print("[NewSDK][Phase1] sessionCloseUsingNewSDK called")
    }

    /// NewSDK 経由で受信したチャットテキストを処理する（旧 DATACONNECTION_EVENT_DATA と同等）
    /// - メインスレッドから呼ぶこと
    func handleIncomingChat(text: String) {
        print("[CHAT][NEWSDK][RECV] peer=NewSDK len=\(text.count) textHead=\(String(text.prefix(30)))")
        if text.contains("画面リフレッシュ") {
            isReconnect = true
            castSelectedDialog.infoLbl.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 0)
            castSelectedDialog.infoLbl.attributedText = UtilFunc.getInsertIconString(
                string: "画面をリフレッシュしています。", iconImage: UIImage(), iconSize: iconSize, lineHeight: 1.5)
            castSelectedDialog.infoLbl.font = UIFont.boldSystemFont(ofSize: 15)
            castSelectedDialog.infoLbl.sizeToFit()
            castSelectedDialog.infoLbl.center = castSelectedDialog.center
            castSelectedDialog.infoLbl.isHidden = false
            castSelectedDialog.bringSubviewToFront(castSelectedDialog.infoLbl)
            castSelectedDialog.closeBtn.isHidden = true
            castSelectedDialog.isHidden = false
            appDelegate.window!.bringSubviewToFront(castSelectedDialog)
            return
        }
        let message = Message(sender: Message.SenderType.get, text: text)
        messages.insert(message, at: messages.count)
        castWaitDialog.messageTableView.reloadData()
        if text.hasPrefix("$$$_nocoin_") {
            castWaitDialog.messageTableView.isHidden = false
            liveTimelineFlg = 1
            timelineBtn.image = UIImage(named: "lm_ico_on")!.withRenderingMode(UIImage.RenderingMode.alwaysOriginal)
        }
    }
}

// MARK: - SkywaySessionDelegate (Phase2-4c-2)
extension WaitViewController: SkywaySessionDelegate {
    func sessionStart() {
        let peerId = SkywayManager.sharedManager().getPeerId()
        print("[NewSDK] WaitViewController: sessionStart")
        print("[NewSDK] peerId generated: \(peerId)")

        // peerId を UserDefaults に保存（ユーザー側で部屋選択時に使用）
        // TODO: use stable castId as roomName (現在はpeerId=UUIDを暫定使用)
        UserDefaults.standard.set(peerId, forKey: "skyway_peer_id")
        print("[NewSDK] saved skyway_peer_id to UserDefaults: \(peerId)")

        // キャスト側もルームに参加 + publish（自分の peerId をルーム名として使用）
        // TODO: use stable castId as roomName
        let roomName = peerId
        print("[NewSDK] WaitViewController: joining room as host, roomName=\(roomName)")
        self.configureAudioSessionForSpeaker()
        self.addAudioSessionObservers()
        SkywayManager.sharedManager().connectStart(roomName: roomName, delegate: self)
    }
    func connectSucces() {
        let mgr = SkywayManager.sharedManager()
        let pubInfo = mgr.localPublicationInfo()
        print("[DIAG][FLOW] connectSucces ENTER waitState=\(waitState) isLiveConnectionStarted=\(isLiveConnectionStarted) \(mgr.diagPublishState)")
        print("[DIAG][CONNECT] localPublications count=\(pubInfo.count) details=\(pubInfo)")
        setWaitState(.waiting)
        mgr.setWaitLocal(localView: localStreamView, delegate: self)
        mgr.setRemoteView(remoteView: remoteStreamView)

        // NewSDK: Room参加 + publish 完了後に CastLock を解除
        UtilFunc.deleteCastLock(cast_id: self.user_id, user_id: self.user_id, type: 1)
        UtilFunc.deleteCastLock(cast_id: self.user_id, user_id: 0, type: 2)
        print("[DIAG][CONNECT] deleteCastLock done")

        print("[READY][connectSucces] before isSkyWayReady=\(isSkyWayReady) isNewSDKReadyForApproval=\(isNewSDKReadyForApproval) waitState=\(waitState) peer=\(peer == nil ? "nil" : "exists")")
        print("[DIAG][SYNC_CALL] from=connectSucces")
        self.syncLivePoint()

        // local publication に audio + video が揃っている場合のみ ready
        // publish() が返っても SDK 内部の sender 構築が未完了の場合があり、
        // 揃っていない状態で承認 → リスナー subscribe → sender.cpp:78 crash になる
        let hasVideoPub = pubInfo.contains(where: { $0.contains("video") })
        let hasAudioPub = pubInfo.contains(where: { $0.contains("audio") })
        let previewOk = mgr.isLocalPreviewAttached
        print("[DIAG][READY] connectSucces pubCheck: hasVideoPub=\(hasVideoPub) hasAudioPub=\(hasAudioPub) previewAttached=\(previewOk)")
        isNewSDKReadyForApproval = true

        if hasVideoPub && hasAudioPub && previewOk {
            isSkyWayReady = true
            print("[DIAG][READY] connectSucces isSkyWayReady=true (video+audio pub + preview verified)")
        } else {
            isSkyWayReady = false
            print("[DIAG][READY] connectSucces isSkyWayReady=false — scheduling deferred check")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                let retryInfo = mgr.localPublicationInfo()
                let retryVideo = retryInfo.contains(where: { $0.contains("video") })
                let retryAudio = retryInfo.contains(where: { $0.contains("audio") })
                let retryPreview = mgr.isLocalPreviewAttached
                print("[DIAG][READY] deferred check: pubs=\(retryInfo) hasVideo=\(retryVideo) hasAudio=\(retryAudio) preview=\(retryPreview) \(mgr.diagPublishState)")
                guard retryVideo && retryAudio && retryPreview else {
                    print("[DIAG][READY] deferred: conditions not met, isSkyWayReady remains false")
                    return
                }
                self.isSkyWayReady = true
                print("[DIAG][READY] deferred set isSkyWayReady=true")
                if self.isPendingApproval, let completion = self.pendingApprovalCompletion {
                    let callId = self.pendingRequest?.callId ?? "unknown"
                    print("[SKYWAY][APPROVAL] deferred ready, resuming pending approval callId=\(callId)")
                    self.isPendingApproval = false
                    self.pendingApprovalCompletion = nil
                    completion()  // already on main thread (DispatchQueue.main)
                }
            }
        }

        print("[DIAG][READY] connectSucces END isSkyWayReady=\(isSkyWayReady) isNewSDKReadyForApproval=\(isNewSDKReadyForApproval) waitState=\(waitState)")
        Task { @MainActor in
            self.setWaitState(.waiting)
            if self.isPendingApproval, let completion = self.pendingApprovalCompletion {
                let callId = self.pendingRequest?.callId ?? "unknown"
                if self.isSkyWayReady {
                    print("[SKYWAY][APPROVAL] connectSucces: ready, resuming pending approval callId=\(callId)")
                    self.isPendingApproval = false
                    self.pendingApprovalCompletion = nil
                    DispatchQueue.main.async { completion() }
                } else {
                    print("[SKYWAY][APPROVAL] connectSucces: isSkyWayReady=false, not resuming callId=\(callId)")
                }
            }
        }
    }
    func remoteConnectSucces() {
        print("[DIAG][FLOW] remoteConnectSucces ENTER waitState=\(waitState) isLiveConnectionStarted=\(isLiveConnectionStarted)")
        print("[FLOW][L4] remoteConnectSucces ENTER isLiveConnectionStarted=\(isLiveConnectionStarted) waitState=\(waitState) live_target_user_id=\(appDelegate.live_target_user_id) isNewSDKReadyForApproval=\(isNewSDKReadyForApproval) isSkyWayReady=\(isSkyWayReady)")
        print("[NewSDK] WaitViewController: remoteConnectSucces - ユーザーが参加しました")
        // 多重実行ガード
        guard !isLiveConnectionStarted else {
            print("[DIAG][FLOW] remoteConnectSucces SKIP reason=already_started")
            print("[NewSDK] WaitViewController: remoteConnectSucces skipped - already started")
            return
        }
        // isSkyWayReady ガード: publish 未完了の状態で startConnection に進まない
        guard isSkyWayReady else {
            print("[DIAG][FLOW] remoteConnectSucces SKIP reason=isSkyWayReady_false isNewSDKReadyForApproval=\(isNewSDKReadyForApproval)")
            return
        }
        isLiveConnectionStarted = true
        print("[DIAG][FLOW] remoteConnectSucces PROCEED -> connected + startConnection isSkyWayReady=\(isSkyWayReady)")
        print("[NewSDK] WaitViewController: isLiveConnectionStarted = true")
        // ここで startConnection() 相当の処理を呼ぶ（UI更新など）
        Task { @MainActor in
            self.setWaitState(.connected)
            self.startConnection()
            // SkyWay SDK が AudioSession を上書きした後にスピーカー補正
            self.configureAudioSessionForSpeaker()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.forceSpeakerOnlyWhenNoExternalRoute(reason: "remoteConnectSucces+1s")
            }
            // NewSDK: 旧SDK の DATACONNECTION_EVENT_OPEN で行っていたタイマー起動を補完
            if !self.timerLive.isValid {
                if self.appDelegate.reserveStatus == "1" {
                    self.appDelegate.reserveStatus = "2"
                    print("[NewSDK] remoteConnectSucces: reserveStatus → 2")
                }
                self.appDelegate.count = 0
                self.timerLive = Timer.scheduledTimer(timeInterval: 1.0,
                                                      target: self,
                                                      selector: #selector(self.timerInterruptLive(_:)),
                                                      userInfo: nil,
                                                      repeats: true)
                print("[NewSDK] remoteConnectSucces: timerLive started")
            }

            // NewSDK: 旧SDK の DATACONNECTION_EVENT_OPEN で行っていた userIconImageView 初期化を補完
            // ① タップ有効化 + ② gestureRecognizer 追加（二重登録防止）
            self.userIconImageView.isUserInteractionEnabled = true
            if (self.userIconImageView.gestureRecognizers ?? []).isEmpty {
                self.userIconImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.userIconImageViewTapped(_:))))
            }

            // ③ ターゲットユーザーの情報を取得（プロフィール画像セット）
            self.getTargetInfo(target_id: self.appDelegate.live_target_user_id)

            // ④ OnLiveUserInfo ダイアログ生成（未生成の場合のみ）
            if self.userInfoDialog.superview == nil {
                self.userInfoDialog = UINib(nibName: "OnLiveUserInfo", bundle: nil).instantiate(withOwner: self, options: nil)[0] as! OnLiveUserInfo
                self.userInfoDialog.frame = self.view.frame
                self.view.addSubview(self.userInfoDialog)
                self.userInfoDialog.isHidden = true
            }
        }
    }
    func connectDisconnect() {
        // 注意: このコールバックはUI更新のみに留める
        // SkywayManager の操作（connectStart等）は行わない（memberDidLeave内のleaveRoomIfNeededと競合するため）
        // 再接続が必要な場合は connectEnd() 後に別途トリガーする
        isLiveConnectionStarted = false
        isNewSDKReadyForApproval = false
        isSkyWayReady = false
        print("[DIAG][RESET] connectDisconnect: isSkyWayReady→false isNewSDKReadyForApproval→false isSessionClosing=\(isSessionClosing)")
        print("[NewSDK] WaitViewController: connectDisconnect - isLiveConnectionStarted=false isNewSDKReadyForApproval→false isSessionClosing=\(isSessionClosing)")
        // isSessionClosing が true のとき（status_listener==3 による強制leave中）は
        // commonWaitDo の Task 内で leaveRoomIfNeeded 完了後に setWaitState を行うため、ここではスキップ
        guard !isSessionClosing else {
            print("[NewSDK] WaitViewController: connectDisconnect - skip setWaitState(.waiting) isSessionClosing=true")
            return
        }
        Task { @MainActor in
            self.setWaitState(.waiting)
            self.returnToWaitingUI()
        }
    }

    /// ユーザー退出後の待機画面復帰処理（UI更新のみ）
    @MainActor
    private func returnToWaitingUI() {
        isLiveConnectionStarted = false  // 念のため保証
        print("[NewSDK] WaitViewController: returnToWaitingUI - 待機画面へ復帰")
        // TODO: 待機画面への復帰UI処理を実装
        // 例: カウントダウン非表示、ユーザーアイコン非表示、待機ダイアログ表示など
        // self.countDownLabel.isHidden = true
        // self.userIconImageView.isHidden = true
        // self.castWaitDialog.waitDialogView.isHidden = false
    }
    func connectEnd() {
        isLiveConnectionStarted = false
        isNewSDKReadyForApproval = false
        isSkyWayReady = false
        print("[DIAG][RESET] connectEnd: isSkyWayReady→false isNewSDKReadyForApproval→false")
        print("[NewSDK] WaitViewController: connectEnd - ルームが閉じられました isNewSDKReadyForApproval→false isLiveConnectionStarted=false")
        Task { @MainActor in
            self.setWaitState(.idle)
        }
    }
    func connectError() {
        print("[DIAG][RESET] connectError ENTER isSkyWayReady=\(isSkyWayReady) isNewSDKReadyForApproval=\(isNewSDKReadyForApproval) isLiveConnectionStarted=\(isLiveConnectionStarted) waitState=\(waitState) \(SkywayManager.sharedManager().diagPublishState)")
        isLiveConnectionStarted = false
        isSkyWayReady = false
        isNewSDKReadyForApproval = false
        setWaitState(.idle)
        // 旧SDKでは PEER_EVENT_ERROR でも deleteCastLock を呼んでいた (line 448-449, 461-469)
        UtilFunc.deleteCastLock(cast_id: self.user_id, user_id: self.user_id, type: 1)
        UtilFunc.deleteCastLock(cast_id: self.user_id, user_id: 0, type: 2)
        print("[DIAG][RESET] connectError: isSkyWayReady→false isNewSDKReadyForApproval→false isPendingApproval=\(isPendingApproval)")
        DispatchQueue.main.async { [weak self] in
            self?.isNewSDKReadyForApproval = false
            self?.isSkyWayReady = false
            if self?.isPendingApproval == true {
                print("[NewSDK] connectError: clearing isPendingApproval to break deadlock")
                self?.isPendingApproval = false
                self?.pendingApprovalCompletion = nil
            }
        }
    }
}

// MARK: - CastWaitDialogDelegate
extension WaitViewController: CastWaitDialogDelegate {
    func castWaitDialogDidRequestCancelWait(_ dialog: CastWaitDialog) {
        print("[NewSDK] castWaitDialogDidRequestCancelWait: beginning leave process")

        // cancelWait ボタン経由であることを記録（完了時に画面遷移するため）
        self.isCancelWaitFlow = true

        Task { @MainActor in
            self.setWaitState(.stopping)
        }

        self.closeMedia()
        self.sessionClose()
    }

    /// 承認ボタン押下時にSkyWay準備状態を確認し、準備完了後にcompletionを呼ぶ。
    /// isSkyWayReady=true なら即時実行。false なら pending にして PEER_EVENT_OPEN で再開。
    func castWaitDialogNeedsSkyWayReady(_ dialog: CastWaitDialog, completion: @escaping () -> Void) {
        let manager = SkywayManager.sharedManager()
        let sessionHealthy = manager.isSessionHealthy
        let allowApproval = isNewSDKReadyForApproval && isSkyWayReady && waitState == .waiting && !isPendingApproval && sessionHealthy
        print("[DIAG][APPROVAL] ENTER isNewSDKReadyForApproval=\(isNewSDKReadyForApproval) isSkyWayReady=\(isSkyWayReady) waitState=\(waitState) isPendingApproval=\(isPendingApproval) sessionHealthy=\(sessionHealthy) allowApproval=\(allowApproval) \(manager.diagPublishState)")
        let callId = pendingRequest?.callId ?? "unknown"

        // completion を必ず main thread で実行するラッパー
        let mainCompletion: () -> Void = {
            if Thread.isMainThread {
                completion()
            } else {
                DispatchQueue.main.async { completion() }
            }
        }

        // --- 待機完了: isSkyWayReady + isNewSDKReadyForApproval 両方必須 ---
        if allowApproval {
            print("[SKYWAY][APPROVAL] castWaitDialogNeedsSkyWayReady: READY callId=\(callId) allowApproval=true waitState=\(waitState)")
            DispatchQueue.main.async {
                mainCompletion()
            }
            return
        }

        // --- 二重承認防止: 既に pending なら無視 ---
        if isPendingApproval {
            print("[SKYWAY][APPROVAL] castWaitDialogNeedsSkyWayReady: ALREADY_PENDING callId=\(callId) isSkyWayReady=\(isSkyWayReady) peerNil=\(peer == nil)")
            return
        }

        // --- NewSDK 未準備: completion を保存して旧SDK再接続 or connectSucces() 待ち ---
        print("[SKYWAY][APPROVAL] castWaitDialogNeedsSkyWayReady: NOT_READY callId=\(callId) isNewSDKReadyForApproval=false isSkyWayReady=\(isSkyWayReady) isReconnecting=\(isReconnecting)")
        isPendingApproval = true
        pendingApprovalCompletion = { [weak self] in
            guard self != nil else { return }
            DispatchQueue.main.async {
                mainCompletion()
            }
        }

        // isReconnecting 中なら再接続は開始しない（OPEN待ちに任せる）
        if isReconnecting {
            print("[SKYWAY][APPROVAL] castWaitDialogNeedsSkyWayReady: RECONNECT_IN_PROGRESS callId=\(callId)")
            return
        }

        // NewSDKモード: 旧SDK reconnect は不要（connectSucces() 待ちに任せる）
        if useNewSDK {
            print("[SKYWAY][APPROVAL] castWaitDialogNeedsSkyWayReady: SKIPPED setupSkyWayReconnect (NewSDK mode) callId=\(callId)")
            return
        }

        setupSkyWayReconnect(reason: "approval_button_pressed")
    }
}
