;;; look-mode.el --- quick file viewer for image and text file browsing -*- lexical-binding: t; -*-

;;; Copyright (C) 2008,2009,2019,2022 Peter H. Mao

;; Author: Peter H. Mao <peter.mao@gmail.com> <petermao@jpl.nasa.gov>
;; Version %Id: 14%

;; look-mode.el is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version. (http://www.gnu.org/licenses/gpl-3.0.txt)

;; look-mode.el is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.

;;; Change log:
;;
;; 2022-01-31: Merged Vapnik's mods up to 2015-10-15
;;             improved/refactored look-at-(next|previous)-file
;;             customizable file settings
;;             look-at-nth-file
;;             look-at-specific-file
;;             look-re-search-forward
;;             look-re-search-backward
;;             look-remove-this-file
;;             look-insert-file
;;             look-reverse-files
;;             look-move-current-file
;;             look-sort-files
;;
;; 2022-01-29: Importing vapnik's changes. 'fundamental-mode -> (default-value 'major-mode)
;;
;; 2019-02-12: default-major-mode is gone as of emacs 26.1, replace with 'fundamental-mode
;;
;; 2009-10-02: fixed look-pwd to properly handle dirs with spaces
;;
;; 2009-08-21: added function look-at-this-file to fix bug in arxiv-reader
;;
;; 2009-01-08: fixed regexp in look-list-subdirectories-recursively

;;; Commentary:
;;
;; This package provides a function to load a list of files into a
;; temporary buffer for viewing.  The buffer (*look*) is writable, but
;; not directly associated with the source material.  The original
;; rationale was that when used with `eimp' (Emacs Image Manipulation
;; Package), one could resize images without any danger of overwriting
;; the original file; however, as of 2022-02, `eimp' is no required by
;; `look-mode'.  This may also be of interest to someone wishing to
;; scan the files of a directory.
;;
;; After loading, M-l is bound to `look-at-files' from dired.  If
;; there is more than one marked file in the current dired view, those
;; files are passed to `look-at-files' as the file list, otherwise,
;; the user is prompted for a file glob.  One moves through the file
;; list using the keybindings: C-. or M-n (`look-at-next-file') C-, or
;; M-p (`look-at-previous-file')
;;
;; In the *look* buffer, C-c l accesses the Customize interface for
;; the "look" group.
;;
;; In 2015, "Joe Bloggs <vapniks@yahoo.com>" added a lot of additional
;; functionality to look-mode.  This version branches from his commit
;; [546b261], with bugfixes applied before git cherry-picking.
;; Additional functionality:
;; Navigation
;; `look-at-nth-file'
;; `look-at-specific-file'
;; Search
;; `look-re-search-forward'
;; `look-re-search-backward'
;; List Manipulation
;; `look-remove-this-file'
;; `look-insert-file'
;; `look-move-current-file'
;; `look-sort-files'

;;; Setup:
;;
;; put this file and eimp.el into a directory in your load-path
;; or cons them onto your load-path.
;; ex: (setq load-path (cons "~/my_lisp_files/" load-path))
;;     (load "look-mode")
;; eimp gets loaded if jpg's are identified

;;; Usage:
;;
;; (look-at-files &optional ls-args)
;;
;; LS-ARGS (string) are the arguments that you would give ls to get the
;; desired file list.
;;
;; two lists are set up: the file list and the subdirectory list
;; to display the subdirectories on the header line, set
;; look-show-subdirs to 't'
;;
;; Exclusion of files is difficult with ls, so I added some
;; functionality to exclude files matching given regexps.  To use
;; this feature, add the regexp as a string constant to the variable
;; look-skip-file-list. For example,
;; (add-to-list 'look-skip-file-list "^n[eo]")
;; will exclude files matching the cmd line ne* and no* I use this
;; with my arXiv reader and then issue a
;; (pop look-skip-file-list) afterwards to reset the list
;; look-skip-directory-list works in the same fashion.

;;; Bugs:
;;
;; 1. can't handle zip files, so they are excluded by default

;;; Future:
;; see arxiv-reader

;;; Code:

;; Customizations
(defgroup look nil
  "View files in a temporary, writeable buffer."
  :prefix "look-"
  :group 'applications)
(defcustom look-skip-file-list '(".zip$")
  "List of regular filename regexps to skip over."
  :group 'look
  :type '(repeat regexp))
(defcustom look-skip-directory-list nil
  "List of directory name regexps to skip over."
  :group 'look
  :type '(repeat regexp))
(defcustom look-show-subdirs nil
  "'t' means show subdirectories on the header line."
  :group 'look
  :type 'boolean)
(defcustom look-recurse-dirlist t
  "Incorporate all subdirectories of matching directories into `look-subdir-list'."
  :group 'look
  :type 'boolean)

(defcustom look-file-settings-templates
  '((doc-view-mode . `(progn (setq doc-view-image-width ,doc-view-image-width)
                             (doc-view-goto-page ,(doc-view-current-page))
                             (image-next-line ,(window-vscroll))
                             (set-window-hscroll nil ,(window-hscroll))))
    (pdf-view-mode . `(progn (setq pdf-view-display-size ',pdf-view-display-size)
                             (pdf-view-goto-page ,(pdf-view-current-page))
                             (image-next-line ,(window-vscroll))
                             (set-window-hscroll nil ,(window-hscroll)))))
  "Extra information used by `look-at-this-file' to display files.
This is a alist whose keys are `major-mode' symbols, and whose
values are sexps to be evaluated in the `look-buffer' for saving
extra information such as image size, page number, etc.
The sexp should return another sexp that sets the image size,
page number etc, and will be evaluated when the file is visited again."
  :group 'look
  :type '(alist :key-type (symbol :tag "Major mode")
                :value-type (sexp :tag "List")))

(defcustom look-default-file-settings
  '((doc-view-mode . (doc-view-fit-height-to-window))
    (pdf-view-mode . (pdf-view-fit-height-to-window)))
  "Alist of default values for `look-file-settings'.
Each element is a cons cell whose car is a `major-mode' symbol,
and whose cdr is an sexp to be evaluated in files with that mode."
  :group 'look
  :type '(alist :key-type (symbol :tag "Major mode")
                :value-type (sexp :tag "List")))

;; Variables that make the code work
(defvar look-file-settings nil
  "Alist of filenames and sexps to evaluate when the file is visited.")
(defvar look-forward-file-list nil
  "List of files stored by the command `look-at-files' for future viewing.")
(defvar look-reverse-file-list nil
  "List of files stored by the command `look-at-files' for reverse lookup.")
(defvar look-subdir-list nil
  "Subdirectories found in the file listing.")
(defvar look-hilight-subdir-index 1
  "Subdirectory index to hilight.")
(defvar look-current-file nil
  "The file being viewed in the `look-buffer'.")
(defvar look-pwd nil
  "The directory that look started in.")
(defvar look-buffer "*look*"
  "Default buffer for look mode.")
;;overlay code suggested by Martin Rudalics
;;http://lists.gnu.org/archive/html/bug-gnu-emacs/2008-12/msg00195.html
(defvar look-header-overlay (make-overlay (point-min) (point-min))
  "Makes overlay at top of buffer.")
(defvar look-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-.") 'look-at-next-file)
    (define-key map (kbd "C-,") 'look-at-previous-file)
    (define-key map (kbd "M-n") 'look-at-next-file)
    (define-key map (kbd "M-p") 'look-at-previous-file)
    (define-key map (kbd "M-#") 'look-at-nth-file)
    (define-key map (kbd "M-/") 'look-at-specific-file)
    (define-key map (kbd "M-k") 'look-remove-this-file)
    (define-key map (kbd "C-s") 'look-re-search-forward)
    (define-key map (kbd "C-r") 'look-re-search-backward)
    (define-key map (kbd "M-^") 'look-sort-files)
    (define-key map (kbd "M-R") 'look-reverse-files)
    (define-key map (kbd "M-~") 'look-move-current-file)
    (define-key map (kbd "C-c l") (lambda () (interactive) (customize-group 'look)))
    map)
  "Keymap for Look mode.")
(easy-menu-define look-menu look-minor-mode-map
  "Menu for look-mode."
  '("Look"
    ["Prev"    look-at-previous-file  ]
    ["Next"    look-at-next-file      ]
    ["Search>" look-re-search-forward ]
    ["<Search" look-re-search-backward]
    ["ibuffer" ibuffer                ]
    ))
(progn
  (makunbound 'look-tool-bar-map) ;; makes the tool bar easily hackable.
  (defvar look-tool-bar-map
    (let ((map (make-sparse-keymap)))
      (tool-bar-local-item-from-menu 'look-at-previous-file "left-arrow" map look-minor-mode-map
                                     :rtl "right-arrow"
                                     :label "Back"
                                     :vert-only t)
      (tool-bar-local-item-from-menu 'look-at-next-file "right-arrow" map look-minor-mode-map
                                     :rtl "left-arrow"
                                     :label "Forward"
                                     :vert-only t)
      (define-key-after map [separator-1] menu-bar-separator)
      (tool-bar-local-item-from-menu 'look-re-search-backward "search" map look-minor-mode-map
                                     :label "C-r")
      (tool-bar-local-item-from-menu 'look-re-search-forward  "search" map look-minor-mode-map
                                     :label "C-s")
      (define-key-after map [separator-2] menu-bar-separator)
      (tool-bar-local-item-from-menu 'kill-this-buffer "close" map global-map          :label "")
      (tool-bar-local-item-from-menu 'ibuffer          "index" map look-minor-mode-map :label "")
      map)))

(defvar look-sort-predicates '((name . string-lessp)
                               (age . (lambda (a b)
                                        (time-less-p (cl-fifth (file-attributes a))
                                                     (cl-fifth (file-attributes b)))))
                               (size . (lambda (a b)
                                         (<= (cl-eighth (file-attributes a))
                                             (cl-eighth (file-attributes b))))))
  "List of sorting predicate functions.")

(unless (and (fboundp 'ido-choose-function)
             (boundp 'ido-read-function-history))
  (defvar ido-read-function-history nil
    "A history list of Lisp expressions forf `ido-choose-function'.
Keeps track of Lisp expressions entered by the user, (but not functions
selected from the list).")

  (defun ido-choose-function (funcs &optional prompt other)
    "Prompt the user for one of the functions in FUNCS.
FUNCS should a list of cons cells whose cars are the function names,
 (either strings or symbols), and whose cdrs are the functions themselves.
If PROMPT is non-nil use that as the prompt.
If OTHER is non-nil allow the user to enter a function of their own.
If OTHER is a string, use that as the prompt when asking the user to
enter a function of their own."
    (cl-flet ((asstring (x) (if (symbolp x) (symbol-name x)
                              (if (stringp x) x
                                (error "Invalid element: %S" x)))))
      (let* ((names (mapcar (lambda (x) (asstring (car x))) funcs))
             (otherstr (if other
                           (if (not (member "other" names))
                               "other"
                             "user function")))
             (otherprompt (if other
                              (if (stringp other)
                                  other
                                "User function: ")))
             (choice (ido-completing-read
                      (or prompt "Function: ")
                      (append (if otherstr (list otherstr)) names)
                      nil nil nil 'ido-functions-history))
             (func (if (equal choice otherstr)
                       (read-from-minibuffer
                        otherprompt nil nil t 'ido-read-function-history)
                     (cdr (cl-assoc choice funcs
                                    :test (lambda (a b) (equal (asstring a)
                                                               (asstring b))))))))
        (if (functionp func) func (error "Invalid function: %S" func))))))

(define-minor-mode look-mode
  "A minor mode for flipping through files."
  :init-value nil ; maybe make this t?
  :lighter " Look"
  :keymap look-minor-mode-map
  (setq-local tool-bar-map look-tool-bar-map))

;;;###autoload
(add-hook 'dired-mode-hook
          (lambda ()
            (define-key dired-mode-map "\M-l" 'look-at-files)))

(defun look-reset-variables ()
  "Re-initializes look-mode's variables."
  (interactive)
  (setq look-forward-file-list nil)
  (setq look-reverse-file-list nil)
  (setq look-subdir-list nil)
  (setq look-skip-file-list '(".zip$"))
  (setq look-skip-directory-list nil)
  (setq look-show-subdirs nil)
  (setq look-current-file nil)
  (setq look-file-settings nil)
  (setq look-buffer "*look*"))

;;;; Navigation Commands

;;;###autoload
(defun look-at-files (&optional add)
  "Look at files in directory.  Insert into temporary buffer one at a time.
This function gets the file list from `dired-get-marked-files' OR
by expanding LOOK-WILDCARD with `file-expand-wildcards', and
passes it to `look-at-next-file'.  If ADD is non-nil (set by
prefix arg such as C-u) then files are added to the end of the
currently looked at files, otherwise they replace them."
  (interactive "P")
  (if (not add)
      (setq look-forward-file-list nil
            look-reverse-file-list nil
            look-current-file nil)
    (push look-current-file look-reverse-file-list)
    (setq look-reverse-file-list (append (nreverse look-forward-file-list) look-reverse-file-list)
          look-current-file (pop look-reverse-file-list)
          look-forward-file-list nil))
  ;; first see if there are any marked files from dired
  (setq look-file-list (dired-get-marked-files t)) ;; will this work outside of dired?
  (unless (cdr look-file-list) ;; ie, 1 or 0 files were marked -- req wildcard from user
    (setq look-wildcard (read-string "Enter filename (w/ wildcards): "))
    ;; (if (and (string-match "[Jj][Pp][Ee]?[Gg]" look-wildcard)
    ;;          (not (featurep 'eimp)))
    ;;     (require 'eimp nil t))
    (if (string= look-wildcard "")
        (setq look-wildcard "*"))
    (setq look-file-list (file-expand-wildcards look-wildcard)))
  (setq look-subdir-list (list "./")
        look-pwd default-directory)
  (let ( (fullpath-dir-list nil))
    ;; use relative file names to prevent weird side effects with skip lists
    ;; cat look-pwd with filename, separate dirs from files,
    ;; remove files/dirs that match elements of the skip lists ;;
    (dolist (lfl-item look-file-list look-forward-file-list)
      (if (and (file-regular-p lfl-item)
               ;; check if any regexps in skip list match filename
               (catch 'skip-this-one
                 (dolist (regexp look-skip-file-list t)
                   (if (string-match regexp lfl-item)
                       (throw 'skip-this-one nil)))))
          (setq look-forward-file-list
                (nconc look-forward-file-list
                       (list (if (file-name-absolute-p lfl-item) lfl-item
                               (concat look-pwd lfl-item)))))
        (if (and (file-directory-p lfl-item)
                 ;; check if any regexps in skip list match directory
                 (catch 'skip-this-one
                   (dolist (regexp look-skip-directory-list t)
                     (if (string-match regexp lfl-item)
                         (throw 'skip-this-one nil)))))
            (if look-recurse-dirlist
                (setq fullpath-dir-list
                      (nconc fullpath-dir-list
                             (list lfl-item)
                             (look-list-subdirectories-recursively
                              (if (file-name-absolute-p lfl-item) lfl-item
                                (concat look-pwd lfl-item))
                              look-skip-directory-list)))
              (setq fullpath-dir-list
                    (nconc fullpath-dir-list
                           (list lfl-item)))))))
    ;; now strip look-pwd off the subdirs in subdirlist
    ;; or maybe I should leave everything as full-path....
    (dolist (fullpath fullpath-dir-list look-subdir-list)
      (setq look-subdir-list
            (nconc look-subdir-list
                   (list (file-name-as-directory
                          (replace-regexp-in-string look-pwd "" fullpath)))))))	;tel
  (get-buffer-create look-buffer)
  (look-at-next-file))

(defun look-at-next-file (&optional arg)
  "Gets the next file in the list.
Discards the file from the list if it is not a regular file or symlink to one.
With prefix arg get the ARG'th next file in the list."
  (interactive "p")		    ; pass no args on interactive call
  (look-save-file-settings look-current-file)
  (dotimes (i (or arg 1))
    (if look-current-file (push look-current-file look-reverse-file-list))
    (setq look-current-file (if look-forward-file-list
                                ;; get the next file in the list
                                (pop look-forward-file-list))))
  (look-at-this-file look-current-file))

(defun look-at-previous-file (&optional arg)
  "Gets the previous file in the list.
With prefix arg get the ARG'th previous file in the list."
  (interactive "p"); pass no args on interactive call
  (look-save-file-settings look-current-file)
  (dotimes (i (or arg 1))
    (if look-current-file (push look-current-file look-forward-file-list))
    (setq look-current-file (if look-reverse-file-list
                                ;; get the next file in the list
                                (pop look-reverse-file-list))))
  (look-at-this-file look-current-file))

(defun look-remove-this-file nil
  "Remove the currently looked at file from the list."
  (interactive)
  (unless (not (y-or-n-p "Remove current file? "))
    (setq look-current-file
          (if look-reverse-file-list	;remove the current file
              (pop look-reverse-file-list)
            (if look-forward-file-list
                (pop look-reverse-file-list))))
    (look-at-this-file look-current-file)))

(defun look-insert-file (file)
  "Insert FILE into the list of looked at files.
File will be inserted in front of current position,
and will become the new currently looked at file."
  (interactive (list (ido-read-file-name
                      "File: "
                      (if look-current-file
                          (file-name-directory look-current-file)))))
  (setq look-reverse-file-list
        (cons look-current-file look-reverse-file-list)
        look-current-file file)
  (look-at-this-file look-current-file))

(defun look-at-nth-file (n)
  "Look at the N'th file in the list.
If N is negative count backwards from the end of the list.
With 0 being the first file, and -1 being the last file,
-2 the second last file, etc."
  (interactive (list (or current-prefix-arg
                         (read-number "Goto position in list (-ve No.s count backwards from end): "))))
  (let ((nback (length look-reverse-file-list))
        (nforward (length look-forward-file-list)))
    (cond ((not (integerp n)) (error "N must be an integer"))
          ((> n (+ nback nforward)) (error "N too large"))
          ((>= n nback) (look-at-next-file (- n nback)))
          ((>= n 0) (look-at-previous-file (- nback n)))
          ((< n (- (+ 1 nback nforward))) (error "N too small"))
          (t (look-at-nth-file (+ n 1 nback nforward))))))

(defun look-at-specific-file (file)
  "Jump to a specific FILE in the `look-mode' list."
  (interactive (list (ido-completing-read
                      "File: "
                      (append look-reverse-file-list look-forward-file-list)
                      nil t)))
  (if (member file look-reverse-file-list)
      (look-at-nth-file (cl-position file look-reverse-file-list :test 'equal))
    (if (member file look-forward-file-list)
        (look-at-nth-file (+ (length look-reverse-file-list)
                             (cl-position file look-forward-file-list :test 'equal)
                             1)))))

(defun look-re-search-forward (regex)
  "Search forward through looked at files for REGEX."
  (interactive (list (read-regexp "Regexp: ")))
  (while (and look-current-file
              (not (cl-case major-mode
                     (pdf-view-mode (pdf-isearch-search-function regex))
                     (doc-view-mode (doc-view-search regex))
                     (t (search-forward regex nil t)))))
    (look-at-next-file)))

(defun look-re-search-backward (regex)
  "Search backward through looked at files for REGEX."
  (interactive (list (read-regexp "Regexp: ")))
  (while (and look-current-file
              (not (cl-case major-mode
                     (pdf-view-mode (pdf-isearch-search-function regex))
                     (doc-view-mode (doc-view-search regex t))
                     (t (search-backward regex nil t)))))
    (look-at-previous-file)
    (goto-char (point-max))))

(defun look-sort-files (pred)
  "Sort the looked at files using function PRED.
PRED is a function of two arguments as used by `sort' (which see)."
  (interactive (list (ido-choose-function
                      look-sort-predicates "Sort predicate: " "Function of 2 args: ")))
  (let* ((allfiles (append (reverse look-reverse-file-list)
                           (if look-current-file
                               (list look-current-file))
                           look-forward-file-list))
         (sortedfiles (sort allfiles pred))
         (pos (if look-current-file
                  (cl-position look-current-file sortedfiles
                               :test 'equal))))
    (setq look-forward-file-list (if pos (cl-subseq sortedfiles (1+ pos))
                                   (if look-forward-file-list sortedfiles))
          look-reverse-file-list (reverse
                                  (if pos (cl-subseq sortedfiles 0 pos)
                                    (if look-reverse-file-list sortedfiles))))
    (look-update-header-line)))

(defun look-reverse-files nil
  "Reverse the order of the looked at files."
  (interactive)
  (let* ((files (reverse (append (reverse look-reverse-file-list)
                                 (if look-current-file (list look-current-file))
                                 look-forward-file-list)))
         (pos (if look-current-file
                  (cl-position look-current-file files :test 'equal))))
    (setq look-forward-file-list (if pos (cl-subseq files (1+ pos))
                                   (if look-forward-file-list files))
          look-reverse-file-list (reverse
                                  (if pos (cl-subseq files 0 pos)
                                    (if look-reverse-file-list files))))
    (look-update-header-line)))

(defun look-move-current-file (pos)
  "Move currently looked at file to position POS in list."
  (interactive (list
                (read-number
                 "Move to position (-ve No.s count backwards from end): ")))
  (let* ((files (append (reverse look-reverse-file-list)
                        look-forward-file-list))
         (nback (length look-reverse-file-list))
         (nforward (length look-forward-file-list))
         (pos2 (cond ((not (integerp pos))
                      (error "Position must be an integer"))
                     ((> pos (+ nback nforward))
                      (error "Position value too large"))
                     ((< pos (- (+ 1 nback nforward)))
                      (error "Position value too small"))
                     ((< pos 0)
                      (+ pos 1 nback nforward))
                     (t pos))))
    (setq look-forward-file-list (cl-subseq files pos2)
          look-reverse-file-list (reverse (cl-subseq files 0 pos2)))
    (look-update-header-line)))

(defun look-reset-file-settings nil
  "Reset the file settings saved in `look-file-settings'.
Note: this will not change the settings for the currently
looked at file."
  (interactive)
  (setq look-file-settings nil))

(defun look-customize-defaults nil
  "Customize `look-default-file-settings'.
This is a convenience function for when you want to
change the default settings for all files."
  (interactive)
  (customize-option 'look-default-file-settings))

(defun look-filter-files (pred &optional arg)
  "Remove all files from the list that don't match PRED.
If prefix arg ARG is non-nil remove files that do match PRED."
  )

;;;; subroutines

(defun look-save-file-settings (file)
  "Save file settings in LOOK-FILE-SETTINGS.  If there is a file
settings template for the major mode of this file, then use it;
otherwise, save the point and window-start positions."
  (when file
    (let ((item (assoc file look-file-settings)))
      (if (assoc major-mode look-file-settings-templates)
          (let ((info (eval (cdr (assoc major-mode look-file-settings-templates)))))
            (if item (setcdr item info)
              (add-to-list 'look-file-settings (cons file info))))
        (let ((info `(progn (goto-char ,(point))
                            (set-window-start nil ,(window-start)))))
          (if item (setcdr item info)
            (add-to-list 'look-file-settings (cons file info))))))))

(defun look-at-this-file (file)
  "Insert FILE into `look-buffer' and set mode appropriately.
When called interactively reload currently looked at file."
  (interactive (list look-current-file))
  (with-current-buffer look-buffer
    (if (memq major-mode '(doc-view-mode pdf-view-mode image-mode))
        (set-buffer-modified-p nil)))
  (kill-buffer look-buffer)		; clear the look-buffer
  (switch-to-buffer look-buffer)	; reopen the look-buffer
  (if (not file)
      (look-no-more)
    (insert-file-contents file) ; insert it into the *look* buffer
    (normal-mode)
    (if (eq major-mode (default-value 'major-mode))
        (look-set-mode-with-auto-mode-alist t))
    (look-update-header-line)
    ;; apply file settings if available
    (if (assoc look-current-file look-file-settings)
        (eval (cdr (assoc look-current-file look-file-settings)))
      ;; otherwise, use the default setting
      (if (assoc major-mode look-default-file-settings)
          (eval (cdr (assoc major-mode look-default-file-settings))))))
  (look-mode))

(defun look-keep-header-on-top (window start)
  "Used by `look-update-header-line' to keep overlay at top of buffer.
Argument WINDOW not used.  Argument START is the start position."
  (move-overlay look-header-overlay start start))

(defun lface-header (text)
  (propertize text 'face 'header-line))
(defun lface-hilite (text)
  (propertize text 'face '(:background "yellow" :foreground "black" :weight bold)))
(defun lface-number (text)
  (propertize text 'face '(:background "grey" :foreground "black" :weight bold)))

(defun look-update-header-line nil
  "Defines the header line for function `look-mode'."
  (let* ((relfilename (file-relative-name look-current-file look-pwd))
         (look-header-line (lface-header
                           (concat "["
                                   (number-to-string (length look-reverse-file-list))
                                   "| "
                                   (substring relfilename (max (- 10 (frame-width))
                                                               (- (length relfilename))))
                                   " |"
                                   (number-to-string (length look-forward-file-list)) "]")))
        (jj 1))
    (if look-show-subdirs
        ; list all but the first item in look-subdir-list
        (while (< jj (length look-subdir-list))
          (setq look-header-line
                (concat look-header-line
                        (if (= jj 1)
                            (lface-header "\n")
                          (lface-header " "))
                        (if (= jj look-hilight-subdir-index)
                            (lface-hilite (number-to-string jj))
                          (lface-number (number-to-string jj)))
                        (lface-header (replace-regexp-in-string ;remove trailing '/'
                                       "/$" "" (nth jj look-subdir-list)))))
          (setq jj (1+ jj))))
    (overlay-put look-header-overlay 'before-string (concat look-header-line
                                                            (lface-header "\n")))
    (move-overlay look-header-overlay (window-start) (window-start) (get-buffer look-buffer))
    (add-hook 'window-scroll-functions 'look-keep-header-on-top nil t)))

(defun look-no-more nil
  "What to do when one gets to the end of a file list."
  (setq look-current-file nil)
  (if look-forward-file-list
      (setq header-line-format
            "No more files to display.  Use look-at-next-file (M-n or C-.[think:>]) to go forward")
    (setq header-line-format
          "No more files to display.  Use look-at-previous-file (M-p or C-,[think:<]) to go back")))

(defun look-set-mode-with-auto-mode-alist (&optional keep-mode-if-same)
  "Taken shamelessly from `set-auto-mode' in files.el (which see).
Uses the `look-current-file' to set the mode using `auto-mode-alist'.
Optional argument KEEP-MODE-IF-SAME passes directly to `set-auto-mode-0'."
  (let ((name look-current-file)
        (remote-id (file-remote-p look-current-file))
        done
        mode)
    ;; Remove remote file name identification.
    (when (and (stringp remote-id)
               (string-match (regexp-quote remote-id) name))
      (setq name (substring name (match-end 0))))
    ;; Remove backup-suffixes from file name.
    (setq name (file-name-sans-versions name))
    (while name
      ;; Find first matching alist entry.
      (setq mode
            (if (memq system-type '(vax-vms windows-nt cygwin))
                ;; System is case-insensitive.
                (let ((case-fold-search t))
                  (assoc-default name auto-mode-alist
                                 'string-match))
              ;; System is case-sensitive.
              (or
               ;; First match case-sensitively.
               (let ((case-fold-search nil))
                 (assoc-default name auto-mode-alist
                                'string-match))
               ;; Fallback to case-insensitive match.
               (and auto-mode-case-fold
                    (let ((case-fold-search t))
                      (assoc-default name auto-mode-alist
                                     'string-match))))))
      (if (and mode
               (consp mode)
               (cadr mode))
          (setq mode (car mode)
                name (substring name 0 (match-beginning 0)))
        (setq name nil))
      (when mode
        (set-auto-mode-0 mode keep-mode-if-same)
        (setq done t)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Generally useful, but here for now ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun look-list-subdirectories-recursively (&optional head-dir exclusion-list)
  "Recursively list directories under HEAD-DIR.
Exclude directory names that match EXCLUSION-LIST."
; for look, this should be relative to look-pwd
  (unless head-dir (setq head-dir "./"))
  (let ((recursive-dir-list nil)
        lsr-dir)
    (dolist (lsr-dir (directory-files head-dir t) recursive-dir-list)
      (if (and (file-directory-p lsr-dir)
               (not (string-match "^\\.\\.?$" (file-name-nondirectory lsr-dir)))
               (not (catch 'found-one
                      (dolist (exclude-regexp exclusion-list nil)
                        (if (string-match exclude-regexp (file-name-nondirectory lsr-dir))
                            (throw 'found-one t))))))
          (setq recursive-dir-list
                (nconc recursive-dir-list
                       (list lsr-dir)
                       (look-list-subdirectories-recursively lsr-dir exclusion-list)))))
    recursive-dir-list))

(provide 'look-mode)

;;; look-mode.el ends here
