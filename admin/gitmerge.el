;;; gitmerge.el --- help merge one Emacs branch into another

;; Copyright (C) 2010-2015 Free Software Foundation, Inc.

;; Authors: David Engster <deng@randomsample.de>
;;          Stefan Monnier <monnier@iro.umontreal.ca>

;; Keywords: maint

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Rewrite of bzrmerge.el, but using git.
;;
;; In a nutshell: For merging foo into master, do
;;
;; - 'git checkout master' in Emacs repository
;; - Start Emacs, cd to Emacs repository
;; - M-x gitmerge
;; - Choose branch 'foo' or 'origin/foo', depending on whether you
;;   like to merge from a local tracking branch or from the remote
;;   (does not make a difference if the local tracking branch is
;;   up-to-date).
;; - Mark commits you'd like to skip, meaning to only merge their
;;   metadata (merge strategy 'ours').
;; - Hit 'm' to start merging. Skipped commits will be merged separately.
;; - If conflicts cannot be resolved automatically, you'll have to do
;;   it manually. In that case, resolve the conflicts and restart
;;   gitmerge, which will automatically resume. It will add resolved
;;   files, commit the pending merge and continue merging the rest.
;; - Inspect master branch, and if everything looks OK, push.

;;; Code:

(require 'vc-git)
(require 'smerge-mode)

(defvar gitmerge-skip-regexp
  "back[- ]?port\\|merge\\|sync\\|re-?generate\\|bump version\\|from trunk\\|\
Auto-commit"
  "Regexp matching logs of revisions that might be skipped.
`gitmerge-missing' will ask you if it should skip any matches.")

(defvar gitmerge-status-file (expand-file-name "gitmerge-status"
					       user-emacs-directory)
  "File where missing commits will be saved between sessions.")

(defvar gitmerge-ignore-branches-regexp
  "origin/\\(\\(HEAD\\|master\\)$\\|\\(old-branches\\|other-branches\\)/\\)"
  "Regexp matching branches we want to ignore.")

(defface gitmerge-skip-face
  '((t (:strike-through t)))
  "Face for skipped commits.")

(defconst gitmerge-default-branch "origin/emacs-24"
  "Default for branch that should be merged.")

(defconst gitmerge-buffer "*gitmerge*"
  "Working buffer for gitmerge.")

(defconst gitmerge-output-buffer "*gitmerge output*"
  "Buffer for displaying git output.")

(defconst gitmerge-warning-buffer "*gitmerge warnings*"
  "Buffer where gitmerge will display any warnings.")

(defvar gitmerge-log-regexp
  "^\\([A-Z ]\\)\\s-*\\([0-9a-f]+\\) \\(.+?\\): \\(.*\\)$")

(defvar gitmerge-mode-map
  (let ((map (make-keymap)))
    (define-key map [(l)] 'gitmerge-show-log)
    (define-key map [(d)] 'gitmerge-show-diff)
    (define-key map [(f)] 'gitmerge-show-files)
    (define-key map [(s)] 'gitmerge-toggle-skip)
    (define-key map [(m)] 'gitmerge-start-merge)
    map)
  "Keymap for gitmerge major mode.")


(defvar gitmerge-mode-font-lock-keywords
  `((,gitmerge-log-regexp
     (1 font-lock-warning-face)
     (2 font-lock-constant-face)
     (3 font-lock-builtin-face)
     (4 font-lock-comment-face))))

(defvar gitmerge--commits nil)
(defvar gitmerge--from nil)

(defun gitmerge-get-sha1 ()
  "Get SHA1 from commit at point."
  (save-excursion
    (goto-char (point-at-bol))
    (when (looking-at "^[A-Z ]\\s-*\\([a-f0-9]+\\)")
      (match-string 1))))

(defun gitmerge-show-log ()
  "Show log of commit at point."
  (interactive)
  (save-selected-window
    (let ((commit (gitmerge-get-sha1)))
      (when commit
	(pop-to-buffer (get-buffer-create gitmerge-output-buffer))
	(fundamental-mode)
	(erase-buffer)
	(call-process "git" nil t nil "log" "-1" commit)
	(goto-char (point-min))
	(gitmerge-highlight-skip-regexp)))))

(defun gitmerge-show-diff ()
  "Show diff of commit at point."
  (interactive)
  (save-selected-window
    (let ((commit (gitmerge-get-sha1)))
      (when commit
	(pop-to-buffer (get-buffer-create gitmerge-output-buffer))
	(erase-buffer)
	(call-process "git" nil t nil "diff-tree" "-p" commit)
	(goto-char (point-min))
	(diff-mode)))))

(defun gitmerge-show-files ()
  "Show changed files of commit at point."
  (interactive)
  (save-selected-window
    (let ((commit (gitmerge-get-sha1)))
      (when commit
	(pop-to-buffer (get-buffer-create gitmerge-output-buffer))
	(erase-buffer)
	(fundamental-mode)
	(call-process "git" nil t nil "diff" "--name-only" (concat commit "^!"))
	(goto-char (point-min))))))

(defun gitmerge-toggle-skip ()
  "Toggle skipping of commit at point."
  (interactive)
  (let ((commit (gitmerge-get-sha1))
	skip)
    (when commit
      (save-excursion
	(goto-char (point-at-bol))
	(when (looking-at "^\\([A-Z ]\\)\\s-*\\([a-f0-9]+\\)")
	  (setq skip (string= (match-string 1) " "))
	  (goto-char (match-beginning 2))
	  (gitmerge-handle-skip-overlay skip)
	  (dolist (ct gitmerge--commits)
	    (when (string-match commit (car ct))
	      (setcdr ct (when skip "M"))))
	  (goto-char (point-at-bol))
	  (setq buffer-read-only nil)
	  (delete-char 1)
	  (insert (if skip "M" " "))
	  (setq buffer-read-only t))))))

(defun gitmerge-highlight-skip-regexp ()
  "Highlight strings that match `gitmerge-skip-regexp'."
  (save-excursion
    (while (re-search-forward gitmerge-skip-regexp nil t)
      (put-text-property (match-beginning 0) (match-end 0)
			 'face 'font-lock-warning-face))))

(defun gitmerge-missing (from)
  "Return the list of revisions that need to be merged from FROM.
Will detect a default set of skipped revision by looking at
cherry mark and search for `gitmerge-skip-regexp'.  The result is
a list with entries of the form (SHA1 . SKIP), where SKIP denotes
if and why this commit should be skipped."
  (let (commits)
    ;; Go through the log and remember all commits that match
    ;; `gitmerge-skip-regexp' or are marked by --cherry-mark.
    (with-temp-buffer
      (call-process "git" nil t nil "log" "--cherry-mark" from
		    (concat "^" (car (vc-git-branches))))
      (goto-char (point-max))
      (while (re-search-backward "^commit \\(.+\\) \\([0-9a-f]+\\).*" nil t)
	(let ((cherrymark (match-string 1))
	      (commit (match-string 2)))
	  (push (list commit) commits)
	  (if (string= cherrymark "=")
	      ;; Commit was recognized as backported by cherry-mark.
	      (setcdr (car commits) "C")
	    (save-excursion
	      (let ((case-fold-search t))
		(while (not (looking-at "^\\s-+[^ ]+"))
		  (forward-line))
		(when (re-search-forward gitmerge-skip-regexp nil t)
		  (setcdr (car commits) "R"))))))
	(delete-region (point) (point-max))))
    (nreverse commits)))

(defun gitmerge-setup-log-buffer (commits from)
  "Create the buffer for choosing commits."
  (with-current-buffer (get-buffer-create gitmerge-buffer)
    (erase-buffer)
    (call-process "git" nil t nil "log"
		  "--pretty=format:%h %<(20,trunc) %an: %<(100,trunc) %s"
		  from (concat "^" (car (vc-git-branches))))
    (goto-char (point-min))
    (while (looking-at "^\\([a-f0-9]+\\)")
      (let ((skipreason (gitmerge-skip-commit-p (match-string 1) commits)))
	(if (null skipreason)
	    (insert "  ")
	  (insert skipreason " ")
	  (gitmerge-handle-skip-overlay t)))
      (forward-line))
    (current-buffer)))

(defun gitmerge-handle-skip-overlay (skip)
  "Create or delete overlay on SHA1, depending on SKIP."
  (when (looking-at "[0-9a-f]+")
    (if skip
	(let ((ov (make-overlay (point)
				(match-end 0))))
	  (overlay-put ov 'face 'gitmerge-skip-face))
      (remove-overlays (point) (match-end 0)
		       'face 'gitmerge-skip-face))))

(defun gitmerge-skip-commit-p (commit skips)
  "Tell whether COMMIT should be skipped.
COMMIT is an (possibly abbreviated) SHA1.  SKIPS is list of
cons'es with commits that should be skipped and the reason.
Return value is string which denotes reason, or nil if commit
should not be skipped."
  (let (found skip)
    (while (and (setq skip (pop skips))
		(not found))
      (when (string-match commit (car skip))
	(setq found (cdr skip))))
    found))

(defun gitmerge-resolve (file)
  "Try to resolve conflicts in FILE with smerge.
Returns non-nil if conflicts remain."
  (unless (file-exists-p file) (error "Gitmerge-resolve: Can't find %s" file))
  (with-demoted-errors
    (let ((exists (find-buffer-visiting file)))
      (with-current-buffer (let ((enable-local-variables :safe)
                                 (enable-local-eval nil))
                             (find-file-noselect file))
        (if (buffer-modified-p)
            (user-error "Unsaved changes in %s" (current-buffer)))
        (save-excursion
          (cond
           ((derived-mode-p 'change-log-mode)
            ;; Fix up dates before resolving the conflicts.
            (goto-char (point-min))
            (let ((diff-auto-refine-mode nil))
              (while (re-search-forward smerge-begin-re nil t)
                (smerge-match-conflict)
                (smerge-ensure-match 3)
                (let ((start1 (match-beginning 1))
                      (end1 (match-end 1))
                      (start3 (match-beginning 3))
                      (end3 (copy-marker (match-end 3) t)))
                  (goto-char start3)
                  (while (re-search-forward change-log-start-entry-re end3 t)
                    (let* ((str (match-string 0))
                           (newstr (save-match-data
                                     (concat (add-log-iso8601-time-string)
                                             (when (string-match " *\\'" str)
                                               (match-string 0 str))))))
                      (replace-match newstr t t)))
                  ;; change-log-resolve-conflict prefers to put match-1's
                  ;; elements first (for equal dates), whereas we want to put
                  ;; match-3's first.
                  (let ((match3 (buffer-substring start3 end3))
                        (match1 (buffer-substring start1 end1)))
                    (delete-region start3 end3)
                    (goto-char start3)
                    (insert match1)
                    (delete-region start1 end1)
                    (goto-char start1)
                    (insert match3)))))
            ;; (pop-to-buffer (current-buffer)) (debug 'before-resolve)
            ))
          ;; Try to resolve the conflicts.
          (cond
           ((member file '("configure" "lisp/ldefs-boot.el"
                           "lisp/emacs-lisp/cl-loaddefs.el"))
            ;; We are in the file's buffer, so names are relative.
            (call-process "git" nil t nil "checkout" "--"
                          (file-name-nondirectory file))
            (revert-buffer nil 'noconfirm))
           (t
            (goto-char (point-max))
            (while (re-search-backward smerge-begin-re nil t)
              (save-excursion
                (ignore-errors
                  (smerge-match-conflict)
                  (smerge-resolve))))
            ;; (when (derived-mode-p 'change-log-mode)
            ;;   (pop-to-buffer (current-buffer)) (debug 'after-resolve))
            (save-buffer)))
          (goto-char (point-min))
          (prog1 (re-search-forward smerge-begin-re nil t)
            (unless exists (kill-buffer))))))))

(defun gitmerge-commit-message (beg end skip branch)
  "Create commit message for merging BEG to END from BRANCH.
SKIP denotes whether those commits are actually skipped.  If END
is nil, only the single commit BEG is merged."
  (with-temp-buffer
    (insert "Merge from " branch "\n\n"
	    (if skip
		(concat "The following commit"
			(if end "s were " " was ")
			"skipped:\n\n")
	      ""))
    (apply 'call-process "git" nil t nil "log" "--oneline"
	   (if end (list (concat beg "~.." end))
	     `("-1" ,beg)))
    (insert "\n")
    (buffer-string)))

(defun gitmerge-apply (missing from)
  "Merge commits in MISSING from branch FROM.
MISSING must be a list of SHA1 strings."
  (with-current-buffer (get-buffer-create gitmerge-output-buffer)
    (erase-buffer)
    (let* ((skip (cdar missing))
	   (beg (car (pop missing)))
	   end commitmessage)
      ;; Determine last revision with same boolean skip status.
      (while (and missing
		  (eq (null (cdar missing))
		      (null skip)))
	(setq end (car (pop missing))))
      (setq commitmessage
	    (gitmerge-commit-message beg end skip from))
      (message "%s %s%s"
	       (if skip "Skipping" "Merging")
	       (substring beg 0 6)
	       (if end (concat ".." (substring end 0 6)) ""))
      (unless end
	(setq end beg))
      (unless (zerop
	       (apply 'call-process "git" nil t nil "merge" "--no-ff"
		      (append (when skip '("-s" "ours"))
			      `("-m" ,commitmessage ,end))))
	(gitmerge-write-missing missing from)
	(gitmerge-resolve-unmerged)))
    missing))

(defun gitmerge-resolve-unmerged ()
  "Resolve all files that are unmerged.
Throw an user-error if we cannot resolve automatically."
  (with-current-buffer (get-buffer-create gitmerge-output-buffer)
    (erase-buffer)
    (let (files conflicted)
      ;; List unmerged files
      (if (not (zerop
		(call-process "git" nil t nil
			      "diff" "--name-only" "--diff-filter=U")))
	  (error "Error listing unmerged files. Resolve manually.")
	(goto-char (point-min))
	(while (not (eobp))
	  (push (buffer-substring (point) (line-end-position)) files)
	  (forward-line))
	(dolist (file files)
	  (if (gitmerge-resolve file)
	      ;; File still has conflicts
	      (setq conflicted t)
	    ;; Mark as resolved
	    (call-process "git" nil t nil "add" file)))
	(when conflicted
	  (with-current-buffer (get-buffer-create gitmerge-warning-buffer)
	    (erase-buffer)
	    (insert "For the following files, conflicts could\n"
		    "not be resolved automatically:\n\n")
	    (call-process "git" nil t nil
			  "diff" "--name-only" "--diff-filter=U")
	    (insert "\nResolve the conflicts manually, then run gitmerge again."
		    "\nNote:\n  - You don't have to add resolved files or "
		    "commit the merge yourself (but you can)."
		    "\n  - You can safely close this Emacs session and do this "
		    "in a new one."
		    "\n  - When running gitmerge again, remember that you must "
		    "that from within the Emacs repo.\n")
	    (pop-to-buffer (current-buffer)))
	  (user-error "Resolve the conflicts manually"))))))

(defun gitmerge-repo-clean ()
  "Return non-nil if repository is clean."
  (with-temp-buffer
      (call-process "git" nil t nil
		    "diff" "--staged" "--name-only")
      (call-process "git" nil t nil
		    "diff" "--name-only")
      (zerop (buffer-size))))

(defun gitmerge-maybe-resume ()
  "Check if we have to resume a merge.
If so, add no longer conflicted files and commit."
  (let ((mergehead (file-exists-p
		    (expand-file-name ".git/MERGE_HEAD" default-directory)))
	(statusexist (file-exists-p gitmerge-status-file)))
    (when (and mergehead (not statusexist))
      (user-error "Unfinished merge, but no record of a previous gitmerge run"))
    (when (and (not mergehead)
	       (not (gitmerge-repo-clean)))
      (user-error "Repository is not clean"))
    (when statusexist
      (if (not (y-or-n-p "Resume merge? "))
	  (progn
	    (delete-file gitmerge-status-file)
	    ;; No resume.
	    nil)
	(message "OK, resuming...")
	(gitmerge-resolve-unmerged)
	;; Commit the merge.
	(when mergehead
	  (with-current-buffer (get-buffer-create gitmerge-output-buffer)
	    (erase-buffer)
	    (unless (zerop (call-process "git" nil t nil
					 "commit" "--no-edit"))
	      (error "Git error during merge - fix it manually"))))
	;; Successfully resumed.
	t))))

(defun gitmerge-get-all-branches ()
  "Return list of all branches, including remotes."
  (with-temp-buffer
    (unless (zerop (call-process "git" nil t nil
				 "branch" "-a"))
      (error "Git error listing remote branches"))
    (goto-char (point-min))
    (let (branches branch)
      (while (not (eobp))
	(when (looking-at "^[^\\*]\\s-*\\(?:remotes/\\)?\\(.+\\)$")
	  (setq branch (match-string 1))
	  (unless (string-match gitmerge-ignore-branches-regexp branch)
	    (push branch branches)))
	(forward-line))
      (nreverse branches))))

(defun gitmerge-write-missing (missing from)
  "Write list of commits MISSING into `gitmerge-status-file'.
Branch FROM will be prepended to the list."
  (with-current-buffer
      (find-file-noselect gitmerge-status-file)
    (erase-buffer)
    (insert
     (prin1-to-string (append (list from) missing))
     "\n")
    (save-buffer)
    (kill-buffer)))

(defun gitmerge-read-missing ()
  "Read list of missing commits from `gitmerge-status-file'."
  (with-current-buffer
      (find-file-noselect gitmerge-status-file)
    (unless (zerop (buffer-size))
      (prog1 (read (buffer-string))
	(kill-buffer)))))

(define-derived-mode gitmerge-mode special-mode "gitmerge"
  "Major mode for Emacs branch merging."
  (set-syntax-table text-mode-syntax-table)
  (setq buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local font-lock-defaults '(gitmerge-mode-font-lock-keywords)))

(defun gitmerge (from)
  "Merge from branch FROM into `default-directory'."
  (interactive
   (if (not (vc-git-root default-directory))
       (user-error "Not in a git tree")
     (let ((default-directory (vc-git-root default-directory)))
       (list
	(if (gitmerge-maybe-resume)
	    'resume
	  (completing-read "Merge branch: " (gitmerge-get-all-branches)
			   nil t gitmerge-default-branch))))))
  (let ((default-directory (vc-git-root default-directory)))
    (if (eq from 'resume)
	(progn
	  (setq gitmerge--commits (gitmerge-read-missing))
	  (setq gitmerge--from (pop gitmerge--commits))
	  ;; Directly continue with the merge.
	  (gitmerge-start-merge))
      (setq gitmerge--commits (gitmerge-missing from))
      (setq gitmerge--from from)
      (when (null gitmerge--commits)
	(user-error "Nothing to merge"))
      (with-current-buffer
	  (gitmerge-setup-log-buffer gitmerge--commits gitmerge--from)
	(goto-char (point-min))
	(insert (propertize "Commands: " 'font-lock-face 'bold)
		"(s) Toggle skip, (l) Show log, (d) Show diff, "
		"(f) Show files, (m) Start merge\n"
		(propertize "Flags:    " 'font-lock-face 'bold)
		"(C) Detected backport (cherry-mark), (R) Log matches "
		"regexp, (M) Manually picked\n\n")
	(gitmerge-mode)
	(pop-to-buffer (current-buffer))))))

(defun gitmerge-start-merge ()
  (interactive)
  (when (not (vc-git-root default-directory))
    (user-error "Not in a git tree"))
  (let ((default-directory (vc-git-root default-directory)))
    (while gitmerge--commits
      (setq gitmerge--commits
	    (gitmerge-apply gitmerge--commits gitmerge--from)))
    (when (file-exists-p gitmerge-status-file)
      (delete-file gitmerge-status-file))
    (message "Merging from %s...done" gitmerge--from)))

(provide 'gitmerge)

;;; gitmerge.el ends here