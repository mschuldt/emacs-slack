;;; slack-websocket.el --- slack websocket interface  -*- lexical-binding: t; -*-

;; Copyright (C) 2015  南優也

;; Author: 南優也 <yuyaminami@minamiyuunari-no-MacBook-Pro.local>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:
(require 'websocket)
(require 'slack-request)
(require 'slack-message)
(require 'slack-team)
(require 'slack-reply)

(defclass slack-typing ()
  ((room :initarg :room :initform nil)
   (limit :initarg :limit :initform nil)
   (users :initarg :users :initform nil)))

(defclass slack-typing-user ()
  ((limit :initarg :limit :initform nil)
   (user-name :initarg :user-name :initform nil)))

(defun slack-ws-open (team)
  (if (and (oref team ws-conn) (websocket-openp (oref team ws-conn)))
      (slack-log "Websocket is Already Open" team)
    (cl-labels
        ((on-message (websocket frame)
                     (slack-ws-on-message websocket frame team))
         (on-open (_websocket)
                  (oset team reconnect-count 0)
                  (oset team connected t))
         (on-close (_websocket)
                   (oset team ws-conn nil)
                   (oset team connected nil)))
      (oset team ws-conn
            (websocket-open (oref team ws-url)
                            :on-message #'on-message
                            :on-open #'on-open
                            :on-close #'on-close
                            :nowait (oref team websocket-nowait))))))

(cl-defun slack-ws-close (&optional team (close-reconnection t))
  (interactive)
  (unless team
    (setq team slack-teams))
  (cl-labels
      ((close (team)
              (slack-ws-cancel-ping-timer team)
              (slack-ws-cancel-ping-check-timers team)
              (when close-reconnection
                (slack-ws-cancel-reconnect-timer team))
              (with-slots (connected ws-conn last-pong) team
                (when ws-conn
                  (websocket-close ws-conn)
                  (slack-log "Slack Websocket Closed" team)))))
    (if (listp team)
        (mapc #'close team)
      (close team))))


(defun slack-ws-send (payload team)
  (with-slots (waiting-send ws-conn) team
    (push payload waiting-send)
    (condition-case _e
        (progn
          (websocket-send-text ws-conn payload)
          (setq waiting-send
                (cl-remove-if #'(lambda (p) (string= payload p))
                              waiting-send)))
      (websocket-closed (slack-ws-reconnect team))
      (websocket-illegal-frame (slack-log "Sent illegal frame." team)
                               (slack-ws-close team))
      (error (slack-ws-reconnect team)))))

(defun slack-ws-resend (team)
  (with-slots (waiting-send) team
    (let ((candidate waiting-send))
      (setq waiting-send nil)
      (cl-loop for msg in candidate
               do (sleep-for 1) (slack-ws-send msg team)))))


(defun slack-ws-on-message (_websocket frame team)
  ;; (message "%s" (slack-request-parse-payload
  ;;                (websocket-frame-payload frame)))
  (when (websocket-frame-completep frame)
    (let* ((payload (slack-request-parse-payload
                     (websocket-frame-payload frame)))
           (decoded-payload (and payload (slack-decode payload)))
           (type (and decoded-payload
                      (plist-get decoded-payload :type))))
      ;; (message "%s" decoded-payload)
      (when (slack-team-event-log-enabledp team)
        (slack-log-websocket-payload decoded-payload team))
      (when decoded-payload
        (cond
         ((string= type "pong")
          (slack-ws-handle-pong decoded-payload team))
         ((string= type "hello")
          (slack-ws-cancel-reconnect-timer team)
          (slack-cancel-notify-adandon-reconnect)
          (slack-ws-set-ping-timer team)
          (slack-ws-resend team)
          (slack-log "Slack Websocket Is Ready!" team))
         ((plist-get decoded-payload :reply_to)
          (slack-ws-handle-reply decoded-payload team))
         ((string= type "message")
          (slack-ws-handle-message decoded-payload team))
         ((string= type "reaction_added")
          (slack-ws-handle-reaction-added decoded-payload team))
         ((string= type "reaction_removed")
          (slack-ws-handle-reaction-removed decoded-payload team))
         ((string= type "channel_created")
          (slack-ws-handle-channel-created decoded-payload team))
         ((or (string= type "channel_archive")
              (string= type "group_archive"))
          (slack-ws-handle-room-archive decoded-payload team))
         ((or (string= type "channel_unarchive")
              (string= type "group_unarchive"))
          (slack-ws-handle-room-unarchive decoded-payload team))
         ((string= type "channel_deleted")
          (slack-ws-handle-channel-deleted decoded-payload team))
         ((or (string= type "channel_rename")
              (string= type "group_rename"))
          (slack-ws-handle-room-rename decoded-payload team))
         ((or (string= type "channel_joined")
              (string= type "group_joined"))
          (slack-ws-handle-room-joined decoded-payload team))
         ((string= type "presence_change")
          (slack-ws-handle-presence-change decoded-payload team))
         ((or (string= type "bot_added")
              (string= type "bot_changed"))
          (slack-ws-handle-bot decoded-payload team))
         ((string= type "file_created")
          (slack-ws-handle-file-created decoded-payload team))
         ((or (string= type "file_deleted")
              (string= type "file_unshared"))
          (slack-ws-handle-file-deleted decoded-payload team))
         ((string= type "file_comment_added")
          (slack-ws-handle-file-comment-added decoded-payload team))
         ((string= type "file_comment_deleted")
          (slack-ws-handle-file-comment-deleted decoded-payload team))
         ((string= type "file_comment_edited")
          (slack-ws-handle-file-comment-edited decoded-payload team))
         ((or (string= type "im_marked")
              (string= type "channel_marked")
              (string= type "group_marked"))
          (slack-ws-handle-room-marked decoded-payload team))
         ((string= type "thread_marked")
          (slack-ws-handle-thread-marked decoded-payload team))
         ((string= type "thread_subscribed")
          (slack-ws-handle-thread-subscribed decoded-payload team))
         ((string= type "im_open")
          (slack-ws-handle-im-open decoded-payload team))
         ((string= type "im_close")
          (slack-ws-handle-im-close decoded-payload team))
         ((string= type "team_join")
          (slack-ws-handle-team-join decoded-payload team))
         ((string= type "user_typing")
          (slack-ws-handle-user-typing decoded-payload team))
         ((string= type "user_change")
          (slack-ws-handle-user-change decoded-payload team))
         ((string= type "member_joined_channel")
          (slack-ws-handle-member-joined-channel decoded-payload team))
         ((string= type "member_left_channel")
          (slack-ws-handle-member-left_channel decoded-payload team))
         ((or (string= type "dnd_updated")
              (string= type "dnd_updated_user"))
          (slack-ws-handle-dnd-updated decoded-payload team))
         ((string= type "star_added")
          (slack-ws-handle-star-added decoded-payload team))
         ((string= type "star_removed")
          (slack-ws-handle-star-removed decoded-payload team))
         )))))

(defun slack-user-typing (team)
  (with-slots (typing typing-timer) team
    (with-slots (limit users room) typing
      (let ((current (float-time)))
        (if (and typing-timer (timerp typing-timer)
                 (< limit current))
            (progn
              (cancel-timer typing-timer)
              (setq typing-timer nil)
              (setq typing nil))
          (if (slack-buffer-show-typing-p
               (get-buffer (slack-room-buffer-name room)))
              (let ((team-name (slack-team-name team))
                    (room-name (slack-room-name room))
                    (visible-users (cl-remove-if
                                    #'(lambda (u) (< (oref u limit) current))
                                    users)))
                (slack-log
                 (format "Slack [%s - %s] %s is typing..."
                         team-name room-name
                         (mapconcat #'(lambda (u) (oref u user-name))
                                    visible-users
                                    ", "))
                 team))))))))

(defun slack-ws-handle-user-typing (payload team)
  (let* ((user (slack-user-name (plist-get payload :user) team))
         (room (slack-room-find (plist-get payload :channel) team)))
    (if (and user room
             (slack-buffer-show-typing-p (get-buffer (slack-room-buffer-name room))))
        (let ((limit (+ 3 (float-time))))
          (with-slots (typing typing-timer) team
            (if (and typing (equal room (oref typing room)))
                (with-slots ((typing-limit limit)
                             (typing-room room) users) typing
                  (setq typing-limit limit)
                  (let ((typing-user (make-instance 'slack-typing-user
                                                    :limit limit
                                                    :user-name user)))
                    (setq users
                          (cons typing-user
                                (cl-remove-if #'(lambda (u)
                                                  (string= (oref u user-name)
                                                           user))
                                              users))))))
            (unless typing
              (let ((new-typing (make-instance 'slack-typing
                                               :room room :limit limit))
                    (typing-user (make-instance 'slack-typing-user
                                                :limit limit :user-name user)))
                (oset new-typing users (list typing-user))
                (setq typing new-typing))
              (setq typing-timer
                    (run-with-timer t 1 #'slack-user-typing team))))))))

(defun slack-ws-handle-team-join (payload team)
  (let ((user (slack-decode (plist-get payload :user))))
    (slack-user-info-request
     (plist-get user :id) team
     :after-success #'(lambda ()
                        (slack-log (format "User %s Joind Team: %s"
                                           (plist-get (slack-user--find (plist-get user :id)
                                                                        team)
                                                      :name)
                                           (slack-team-name team))
                                   team)))))

(defun slack-ws-handle-im-open (payload team)
  (cl-labels
      ((notify
        (im)
        (slack-room-history-request
         im team
         :after-success #'(lambda (&rest _ignore)
                            (slack-log (format "Direct Message Channel with %s is Open"
                                               (slack-user-name (oref im user) team))
                                       team))
         :async t)))
    (let ((exist (slack-room-find (plist-get payload :channel) team)))
      (if exist
          (progn
            (oset exist is-open t)
            (notify exist))
        (with-slots (ims) team
          (let ((im (slack-room-create
                     (list :id (plist-get payload :channel)
                           :user (plist-get payload :user))
                     team 'slack-im)))
            (setq ims (cons im ims))
            (notify im)))))))

(defun slack-ws-handle-im-close (payload team)
  (let ((im (slack-room-find (plist-get payload :channel) team)))
    (when im
      (oset im is-open nil)
      (slack-log (format "Direct Message Channel with %s is Closed"
                         (slack-user-name (oref im user) team))
                 team))))

(defun slack-ws-handle-message (payload team)
  (let ((subtype (plist-get payload :subtype)))
    (cond
     ((and subtype (string= subtype "message_changed"))
      (slack-ws-change-message payload team))
     ((and subtype (string= subtype "message_deleted"))
      (slack-ws-delete-message payload team))
     ((and subtype (string= subtype "message_replied"))
      (slack-thread-update-state payload team))
     (t
      (slack-ws-update-message payload team)))))

(defun slack-ws-change-message (payload team)
  (slack-if-let* ((room-id (plist-get payload :channel))
                  (room (slack-room-find room-id team))
                  (message-payload (plist-get payload :message))
                  (ts (plist-get message-payload :ts))
                  (base (slack-room-find-message room ts))
                  (new-message-payload (plist-put message-payload :edited-at ts))
                  (new-message (slack-message-create new-message-payload
                                                     team
                                                     :room room)))
      (slack-message-update base team t
                            (not (slack-message-changed--copy base new-message)))))


(defun slack-ws-delete-message (payload team)
  (slack-if-let* ((room-id (plist-get payload :channel))
                  (room (slack-room-find room-id team))
                  (ts (plist-get payload :deleted_ts))
                  (message (slack-room-find-message room ts)))
      (slack-message-deleted message room team)))

(defun slack-ws-update-message (payload team)
  (let ((m (slack-message-create payload team))
        (bot_id (plist-get payload :bot_id)))
    (when m
      (if (and bot_id (not (slack-find-bot bot_id team)))
          (slack-bot-info-request bot_id team #'(lambda (team) (slack-message-update m team)))
        (slack-message-update m team)))))

(defun slack-ws-handle-reply (payload team)
  (let ((ok (plist-get payload :ok)))
    (if (eq ok :json-false)
        (let ((err (plist-get payload :error)))
          (slack-log (format "Error code: %s msg: %s"
                             (plist-get err :code)
                             (plist-get err :msg))
                     team))
      (let ((message-id (plist-get payload :reply_to)))
        (if (integerp message-id)
            (slack-message-handle-reply
             (slack-message-create payload team)
             team))))))

(defun slack-ws-handle-reaction-added (payload team)
  (let* ((item (plist-get payload :item))
         (item-type (plist-get item :type))
         (reaction (make-instance 'slack-reaction
                                  :name (plist-get payload :reaction)
                                  :count 1
                                  :users (list (plist-get payload :user)))))
    (cl-labels
        ((update-message (message)
                         (slack-message-append-reaction message reaction item-type)
                         (slack-message-update message team t t)))
      (cond
       ((string= item-type "file_comment")
        (let ((file-id (plist-get item :file)))
          (slack-with-file file-id team
            (slack-with-file-comment (plist-get item :file_comment) file
              (when (oref file-comment is-intro)
                (cl-loop for room in (append (oref team channels)
                                             (oref team ims)
                                             (oref team groups))
                         do (slack-if-let*
                                ((message (slack-room-find-file-share-message room
                                                                              file-id)))
                                (update-message message))))
              (slack-message-append-reaction file-comment reaction)
              (slack-message-update file-comment file team)))))
       ((string= item-type "file")
        (let ((file-id (plist-get item :file)))
          (slack-with-file file-id team
            (slack-message-append-reaction file reaction)
            (slack-message-update file team))))
       ((string= item-type "message")
        (slack-if-let* ((room (slack-room-find (plist-get item :channel) team))
                        (message (slack-room-find-message room (plist-get item :ts))))
            (progn
              (update-message message)
              (slack-reaction-notify payload team room))))))))

(defun slack-ws-handle-reaction-removed (payload team)
  (let* ((item (plist-get payload :item))
         (item-type (plist-get item :type))
         (reaction (make-instance 'slack-reaction
                                  :name (plist-get payload :reaction)
                                  :count 1
                                  :users (list (plist-get payload :user)))))
    (cond
     ((string= item-type "file_comment")
      (let ((file-id (plist-get item :file)))
        (slack-with-file file-id team
          (slack-with-file-comment (plist-get item :file_comment) file
            (when (oref file-comment is-intro)
              (cl-loop for room in (append (oref team channels)
                                           (oref team ims)
                                           (oref team groups))
                       do (slack-if-let*
                              ((message (slack-room-find-file-share-message room
                                                                            file-id)))
                              (progn
                                (slack-message-pop-reaction message
                                                            reaction
                                                            item-type)
                                (slack-message-update message team t t)))))
            (slack-message-pop-reaction file-comment reaction)
            (slack-message-update file-comment file team)))))
     ((string= item-type "file")
      (let ((file-id (plist-get item :file)))
        (slack-with-file file-id team
          (slack-message-pop-reaction file reaction)
          (slack-message-update file team))))
     ((string= item-type "message")
      (slack-if-let* ((room (slack-room-find (plist-get item :channel) team))
                      (message (slack-room-find-message room (plist-get item :ts))))
          (progn
            (slack-message-pop-reaction message reaction)
            (slack-message-update message team t t)
            (slack-reaction-notify payload team room)))))))

(defun slack-ws-handle-channel-created (payload team)
  ;; (let ((id (plist-get (plist-get payload :channel) :id)))
  ;;   (slack-channel-create-from-info id team))
  )

(defun slack-ws-handle-room-archive (payload team)
  (let* ((id (plist-get payload :channel))
         (room (slack-room-find id team)))
    (oset room is-archived t)
    (slack-log (format "Channel: %s is archived"
                       (slack-room-display-name room))
               team)))

(defun slack-ws-handle-room-unarchive (payload team)
  (let* ((id (plist-get payload :channel))
         (room (slack-room-find id team)))
    (oset room is-archived nil)
    (slack-log (format "Channel: %s is unarchived"
                       (slack-room-display-name room))
               team)))

(defun slack-ws-handle-channel-deleted (payload team)
  (let ((id (plist-get payload :channel)))
    (slack-room-deleted id team)))

(defun slack-ws-handle-room-rename (payload team)
  (let* ((c (plist-get payload :channel))
         (room (slack-room-find (plist-get c :id) team))
         (old-name (slack-room-name room))
         (new-name (plist-get c :name)))
    (oset room name new-name)
    (slack-log (format "Renamed channel from %s to %s"
                       old-name
                       new-name)
               team)))

(defun slack-ws-handle-room-joined (payload team)
  (cl-labels
      ((replace-room (room rooms)
                     (cons room (cl-delete-if
                                 #'(lambda (r)
                                     (slack-room-equal-p room r))
                                 rooms))))
    (let* ((c (plist-get payload :channel)))
      (if (plist-get c :is_channel)
          (let ((channel (slack-room-create c team 'slack-channel)))
            (with-slots (channels) team
              (setq channels
                    (replace-room channel channels)))
            (slack-log (format "Joined channel %s"
                               (slack-room-display-name channel))
                       team))
        (let ((group (slack-room-create c team 'slack-group)))
          (with-slots (groups) team
            (setq groups
                  (replace-room group groups)))
          (slack-log (format "Joined group %s"
                             (slack-room-display-name group))
                     team))))))

(defun slack-ws-handle-presence-change (payload team)
  (let* ((id (plist-get payload :user))
         (user (slack-user--find id team))
         (presence (plist-get payload :presence)))
    (plist-put user :presence presence)))

(defun slack-ws-handle-bot (payload team)
  (let ((bot (plist-get payload :bot)))
    (with-slots (bots) team
      (push bot bots))))

(defun slack-ws-handle-file-created (payload team)
  (slack-if-let* ((file-id (plist-get (plist-get payload :file) :id))
                  (room (slack-file-room-obj team))
                  (buffer (slack-buffer-find 'slack-file-list-buffer
                                             room
                                             team)))
      (slack-file-request-info file-id 1 team
                               #'(lambda (file _team)
                                   (slack-buffer-update buffer file)))))

(defun slack-ws-handle-file-deleted (payload team)
  (let ((file-id (plist-get payload :file_id))
        (room (slack-file-room-obj team)))
    (with-slots (messages last-read) room
      (setq messages (cl-remove-if #'(lambda (f)
                                       (string= file-id (oref f id)))
                                   messages)))))
(defun slack-ws-set-ping-timer (team)
  (unless (oref team ping-timer)
    (cl-labels ((ping () (slack-ws-ping team)))
      (oset team ping-timer (run-at-time t 10 #'ping)))))

(defun slack-ws-current-time-str ()
  (number-to-string (time-to-seconds (current-time))))

(defun slack-ws-ping (team)
  (slack-message-inc-id team)
  (with-slots (message-id) team
    (let* ((time (slack-ws-current-time-str))
           (m (list :id message-id
                    :type "ping"
                    :time time))
           (json (json-encode m)))
      (slack-ws-set-check-ping-timer team time)
      (slack-ws-send json team))))

(defun slack-ws-set-check-ping-timer (team time)
  (puthash time (run-at-time (oref team check-ping-timeout-sec)
                             nil #'slack-ws-ping-timeout team)
           (oref team ping-check-timers)))


(defun slack-ws-ping-timeout (team)
  (slack-log "Slack Websocket PING Timeout." team)
  (slack-ws-close team)
  (when (oref team reconnect-auto)
    (if (timerp (oref team reconnect-timer))
        (cancel-timer (oref team reconnect-timer)))
    (oset team reconnect-timer
          (run-at-time t (oref team reconnect-after-sec)
                       #'slack-ws-reconnect team))))

(defun slack-ws-cancel-ping-check-timers (team)
  (maphash #'(lambda (key value)
               (if (timerp value)
                   (cancel-timer value)))
           (oref team ping-check-timers))
  (slack-team-init-ping-check-timers team))

(defun slack-ws-cancel-ping-timer (team)
  (with-slots (ping-timer) team
    (if (timerp ping-timer)
        (cancel-timer ping-timer))
    (setq ping-timer nil)))

(defvar slack-disconnected-timer nil)
(defun slack-notify-abandon-reconnect ()
  (unless slack-disconnected-timer
    (setq slack-disconnected-timer
          (run-with-idle-timer 5 t
                               #'(lambda ()
                                   (slack-log
                                    "Reconnect Count Exceeded. Manually invoke `slack-start'."
                                    team))))))

(defun slack-cancel-notify-adandon-reconnect ()
  (if (and slack-disconnected-timer
           (timerp slack-disconnected-timer))
      (progn
        (cancel-timer slack-disconnected-timer)
        (setq slack-disconnected-timer nil))))

(defun slack-ws-reconnect (team &optional force)
  (with-slots
      (reconnect-count (reconnect-max reconnect-count-max)) team
    (if (and (not force) reconnect-max (< reconnect-max reconnect-count))
        (progn
          (slack-notify-abandon-reconnect)
          (slack-ws-close team t))
      (cl-incf reconnect-count)
      ;; (slack-team-kill-buffers team)
      (slack-ws-close team nil)
      (slack-log (format "Slack Websocket Try To Reconnect %s/%s" reconnect-count reconnect-max) team)
      (cl-labels
          ((on-error (&key error-thrown &allow-other-keys)
                     (slack-log (format "Slack Reconnect Failed: %s" (cdr error-thrown)) team))
           (on-success (data)
                       (let ((team-data (plist-get data :team))
                             (self-data (plist-get data :self)))
                         (oset team ws-url (plist-get data :url))
                         (oset team domain (plist-get team-data :domain))
                         (oset team id (plist-get team-data :id))
                         (oset team name (plist-get team-data :name))
                         (oset team self self-data)
                         (oset team self-id (plist-get self-data :id))
                         (oset team self-name (plist-get self-data :name))
                         (slack-channel-list-update team)
                         (slack-group-list-update team)
                         (slack-im-list-update team)
                         (slack-bot-list-update team)
                         (cl-loop for buffer in (oref team slack-message-buffer)
                                  do (slack-if-let*
                                         ((live-p (buffer-live-p buffer))
                                          (slack-buffer (with-current-buffer buffer
                                                          (and (bound-and-true-p
                                                                slack-current-buffer)
                                                               slack-current-buffer))))
                                         (slack-buffer-load-missing-messages
                                          slack-buffer)))
                         (slack-team-kill-buffers
                          team :except '(slack-message-buffer
                                         slack-message-edit-buffer
                                         slack-message-share-buffer
                                         slack-room-message-compose-buffer))
                         (slack-ws-open team))))
        (slack-authorize team #'on-error #'on-success)))))

(defun slack-ws-cancel-reconnect-timer (team)
  (with-slots (reconnect-timer) team
    (if (timerp reconnect-timer)
        (cancel-timer reconnect-timer))
    (setq reconnect-timer nil)))

(defun slack-ws-handle-pong (payload team)
  (let* ((key (plist-get payload :time))
         (timer (gethash key (oref team ping-check-timers))))
    (when timer
      (cancel-timer timer)
      (remhash key (oref team ping-check-timers)))))

(defun slack-ws-handle-room-marked (payload team)
  (let ((room (slack-room-find (plist-get payload :channel)
                               team))
        (new-unread-count-display (plist-get payload :unread_count_display)))
    (when room
      (with-slots (unread-count-display) room
        (setq unread-count-display new-unread-count-display))
      (slack-update-modeline))))

(defun slack-ws-handle-file-comment-added (payload team)
  (let* ((file-id (plist-get payload :file_id))
         (file (slack-file-find file-id team))
         (comment (slack-file-comment-create (plist-get payload :comment)
                                             file-id)))
    (slack-with-file file-id team
      (slack-add-comment file comment)
      (slack-file-insert-comment file (oref comment id) team))))

(defun slack-ws-handle-file-comment-deleted (payload team)
  (let* ((file-id (plist-get (plist-get payload :file)
                             :id))
         (comment-id (plist-get payload :comment)))
    (slack-with-file file-id team
      (slack-delete-comment file comment-id)
      (slack-file-delete-comment file comment-id team))))

(defun slack-ws-handle-thread-marked (payload team)
  (let* ((subscription (plist-get payload :subscription))
         (thread-ts (plist-get subscription :thread_ts))
         (channel (plist-get subscription :channel))
         (room (slack-room-find channel team))
         (parent (and room (slack-room-find-message room thread-ts))))
    (when (and parent (oref parent thread))
      (slack-thread-marked (oref parent thread) subscription))))

(defun slack-ws-handle-thread-subscribed (payload team)
  (let* ((thread-data (plist-get payload :subscription))
         (room (slack-room-find (plist-get thread-data :channel) team))
         (message (and (slack-room-find-message room (plist-get thread-data :thread_ts))))
         (thread (and message (oref message thread))))
    (when thread
      (slack-thread-marked thread thread-data))))

(defun slack-ws-handle-user-change (payload team)
  (let* ((user (plist-get payload :user))
         (id (plist-get user :id)))
    (with-slots (users) team
      (setq users
            (cons user
                  (cl-remove-if #'(lambda (u)
                                    (string= id (plist-get u :id)))
                                users))))))

(defun slack-ws-handle-member-joined-channel (payload team)
  (let ((user (plist-get payload :user))
        (channel (slack-room-find (plist-get payload :channel) team)))
    (when channel
      (cl-pushnew user (oref channel members)
                  :test #'string=))))

(defun slack-ws-handle-member-left_channel (payload team)
  (let ((user (plist-get payload :user))
        (channel (slack-room-find (plist-get payload :channel) team)))
    (when channel
      (oset channel members
            (cl-remove-if #'(lambda (e) (string= e user))
                          (oref channel members))))))

(defun slack-ws-handle-dnd-updated (payload team)
  (let* ((user (slack-user--find (plist-get payload :user) team))
         (updated (slack-user-update-dnd-status user (plist-get payload :dnd_status))))
    (oset team users
          (cons updated (cl-remove-if #'(lambda (user) (string= (plist-get user :id)
                                                                (plist-get updated :id)))
                                      (oref team users))))))

;; [star_added event | Slack](https://api.slack.com/events/star_added)
(defun slack-ws-handle-star-added (payload team)
  (let* ((item (plist-get payload :item))
         (item-type (plist-get item :type)))
    (cl-labels
        ((update-message (message)
                         (slack-message-star-added message)
                         (slack-message-update message team t t)))
      (cond
       ((string= item-type "file_comment")
        (let* ((file-id (plist-get (plist-get item :file) :id))
               (comment-id (plist-get (plist-get item :comment) :id))
               (file (slack-file-find file-id team)))
          (cl-labels
              ((update (&rest _args)
                       (slack-with-file file-id team
                         (slack-with-file-comment comment-id file
                           (slack-message-star-added file-comment)
                           (slack-message-update file-comment file team))

                         (cl-loop for channel in (slack-file-channel-ids file)
                                  do (slack-if-let* ((channel (slack-room-find channel team))
                                                     (message (slack-room-find-file-comment-message
                                                               channel comment-id)))
                                         (update-message message))))))
            (if file (update)
              (slack-file-request-info file-id 1 team #'update)))))
       ((string= item-type "file")
        (let* ((file-id (plist-get (plist-get item :file) :id))
               (file (slack-file-find file-id team)))
          (cl-labels
              ((update (&rest _args)
                       (slack-with-file file-id team
                         (slack-message-star-added file)
                         (slack-message-update file team)

                         (cl-loop for channel in (slack-file-channel-ids file)
                                  do (slack-if-let* ((channel (slack-room-find channel team))
                                                     (message (slack-room-find-file-share-message
                                                               channel (oref file id))))
                                         (update-message message))))))
            (if file (update)
              (slack-file-request-info file-id 1 team #'update)))))
       ((string= item-type "message")
        (slack-if-let* ((room (slack-room-find (plist-get item :channel) team))
                        (ts (plist-get (plist-get item :message) :ts))
                        (message (slack-room-find-message room ts)))
            (update-message message)))))
    (slack-if-let* ((star (oref team star)))
        (slack-star-add star item team))))


(defun slack-ws-handle-star-removed (payload team)
  (let* ((item (plist-get payload :item))
         (item-type (plist-get item :type)))
    (cl-labels
        ((update-message (message)
                         (slack-message-star-removed message)
                         (slack-message-update message team t t)))
      (cond
       ((string= item-type "file_comment")
        (let* ((file-id (plist-get (plist-get item :file) :id))
               (comment-id (plist-get (plist-get item :comment) :id))
               (file (slack-file-find file-id team)))
          (cl-labels
              ((update (&rest _args)
                       (slack-with-file file-id team
                         (slack-with-file-comment comment-id file
                           (slack-message-star-removed file-comment)
                           (slack-message-update file-comment file team))

                         (cl-loop for channel in (slack-file-channel-ids file)
                                  do (slack-if-let* ((channel (slack-room-find channel team))
                                                     (message (slack-room-find-file-comment-message
                                                               channel comment-id)))
                                         (update-message message))))))
            (if file (update)
              (slack-file-request-info file-id 1 team #'update)))))
       ((string= item-type "file")
        (let* ((file-id (plist-get (plist-get item :file) :id))
               (file (slack-file-find file-id team)))
          (cl-labels
              ((update (&rest _args)
                       (slack-with-file file-id team
                         (slack-message-star-removed file)
                         (slack-message-update file team)

                         (cl-loop for channel in (slack-file-channel-ids file)
                                  do (slack-if-let* ((channel (slack-room-find channel team))
                                                     (message (slack-room-find-file-share-message
                                                               channel (oref file id))))
                                         (update-message message))))))
            (if file (update)
              (slack-file-request-info file-id 1 team #'update)))))
       ((string= item-type "message")
        (slack-if-let* ((room (slack-room-find (plist-get item :channel) team))
                        (ts (plist-get (plist-get item :message) :ts))
                        (message (slack-room-find-message room ts)))
            (update-message message)))))

    (slack-if-let* ((star (oref team star)))
        (slack-star-remove star item team))))

(defun slack-ws-handle-file-comment-edited (payload team)
  (let* ((file-id (plist-get (plist-get payload :file) :id))
         (comment (slack-file-comment-create (plist-get payload :comment) file-id))
         (file (slack-file-find file-id team))
         (edited-at (plist-get payload :event_ts)))
    (cl-labels
        ((update (file)
                 (slack-file-update-comment file comment team edited-at)
                 (slack-with-file-comment (oref comment id) file
                   (slack-message-update file-comment file team))))
      (if file (update file)
        (slack-file-request-info file-id 1 team :after-success #'update)))))

(provide 'slack-websocket)
;;; slack-websocket.el ends here

