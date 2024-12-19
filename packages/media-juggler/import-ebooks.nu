#!/usr/bin/env nu

use std log
use media-juggler-lib *

# Import my EBooks to my collection.
#
# Input files can be in the ACSM, EPUB, and PDF formats.
#
# This script performs several steps to process the ebook file.
#
# 1. Decrypt the ACSM file if applicable.
# 2. Fetch and add metadata to the EPUB and PDF formats.
# 3. Upload the file to object storage.
#
# Information that is not provided will be gleaned from the title of the EPUB file if possible.
#
# The final file is named according to Jellyfin's recommendation.
#
# This ends up like this for an EPUB: "<authors>/<title>.epub".
# For a PDF, the book is stored in its own directory with the metadata.opf and cover.ext files: "<authors>/<title>/<title>.pdf".
#
# I'm considering grouping books by series like this:
# The path for a book in a series will look like "<authors>/<series>/<series-position> - <title>.epub".
# The path for a standalone book will look like "<authors>/<title>.epub".
#
def main [
    ...files: string # The paths to ACSM, EPUB, and PDF files to convert, tag, and upload. Prefix paths with "minio:" to download them from the MinIO instance
    --delete # Delete the original file
    --isbn: string # ISBN of the book
    # --identifiers: string # asin:XXXX
    --ereader: string # Create a copy of the comic book optimized for this specific e-reader, i.e. "Kobo Elipsa 2E"
    --ereader-subdirectory: string = "Books/Books" # The subdirectory on the e-reader in-which to copy
    --keep-acsm # Keep the ACSM file after conversion. These stop working for me before long, so no point keeping them around.
    --minio-alias: string = "jwillikers" # The alias of the MinIO server used by the MinIO client application
    --minio-path: string = "media/Books/Books" # The upload bucket and directory on the MinIO server. The file will be uploaded under a subdirectory named after the author.
    --no-copy-to-ereader # Don't copy the E-Reader specific format to a mounted e-reader
    --output-directory: directory # Directory to place files on the local filesystem if desired
    --skip-upload # Don't upload files to the server
    --title: string # The title of the comic or manga issue
] {
    if ($files | is-empty) {
        log error "No files provided"
        exit 1
    }

    if $isbn != null and ($files | length) > 1 {
        log error "Setting the ISBN for multiple files is not allowed as it can result in overwriting the final file"
        exit 1
    }

    let output_directory = (
        if $output_directory == null {
          if $skip_upload {
            "." | path expand
          } else {
            null
          }
        } else {
          $output_directory | path expand
        }
    )
    if $output_directory != null {
        mkdir $output_directory
    }

    let username = (^id --name --user)
    let ereader_disk_label = (
      if $ereader == null {
        null
      } else {
        $ereader_profiles | where model == $ereader | first | get disk_label
      }
    )
    let ereader_mountpoint = (["/run/media" $username $ereader_disk_label] | path join)
    let ereader_target_directory = ([$ereader_mountpoint $ereader_subdirectory] | path join)
    if $ereader != null and not $no_copy_to_ereader {
      if (^findmnt --target $ereader_target_directory | complete | get exit_code) != 0 {
        ^udisksctl mount --block-device ("/dev/disk/by-label/" | path join $ereader_disk_label) --no-user-interaction
        # todo Parse the mountpoint from the output of this command
      }
      mkdir $ereader_target_directory
    }

    # let original_file = $files | first
    let results = $files | each {|original_file|

    log info $"Importing the file (ansi purple)($original_file)(ansi reset)"

    let temporary_directory = (mktemp --directory "import-ebooks.XXXXXXXXXX")
    log info $"Using the temporary directory (ansi yellow)($temporary_directory)(ansi reset)"

    # try {

    # todo Add support for input files from Calibre using the Calibre ID number?
    let file = (
        if ($original_file | str starts-with "minio:") {
            let file = ($original_file | str replace "minio:" "")
            let target = [$temporary_directory ($file | path basename)] | path join
            log debug $"Downloading the file (ansi yellow)($file)(ansi reset) from MinIO to (ansi yellow)($target)(ansi reset)"
            ^mc cp $file $target
            [$temporary_directory ($file | path basename)] | path join
        } else {
            let target = [$temporary_directory ($original_file | path basename)] | path join
            log debug $"Copying the file (ansi yellow)($original_file)(ansi reset) to (ansi yellow)($target)(ansi reset)"
            cp $original_file $target
            [$temporary_directory ($original_file | path basename)] | path join
        }
    )

    let original_input_format = $file | path parse | get extension

    let original_opf = (
        let opf_file = ($original_file | str replace "minio:" "" | path dirname | path join "metadata.opf");
        if ($original_file | str starts-with "minio:") {
            if (^mc stat $opf_file | complete).exit_code == 0 {
                $opf_file
            }
        } else {
            if ($opf_file | path exists) {
                $opf_file
            }
        }
    )

    if $original_opf != null {
        log debug $"Found OPF metadata file (ansi yellow)($original_opf)(ansi reset)"
    }

    let opf = (
        if $original_opf != null {
            let target = [$temporary_directory ($original_opf | path basename)] | path join
            if ($original_file | str starts-with "minio:") {
                log debug $"Downloading the file (ansi yellow)($original_opf)(ansi reset) to (ansi yellow)($target)(ansi reset)"
                ^mc cp $original_opf $target
            } else {
                log debug $"Copying the file (ansi yellow)($original_opf)(ansi reset) to (ansi yellow)($target)(ansi reset)"
                cp $original_opf $target
            }
            $target
        }
    )

    let original_cover = (
        if ($original_file | str starts-with "minio:") {
            let file = $original_file | str replace "minio:" ""
            let covers = (
                ^mc find ($file | path dirname) --name 'cover.*'
                | lines --skip-empty
                | filter {|f|
                    let components = ($f | path parse);
                    $components.stem == "cover" and $components.extension in $image_extensions
                }
            )
            if not ($covers | is-empty) {
                if ($covers | length) > 1 {
                    rm --force --recursive $temporary_directory
                    return {
                        file: $original_file
                        error: $"Found multiple files looking for the cover image file:\n($covers)\n"
                    }
                } else {
                    $covers | first
                }
            }
        } else {
            let covers = (glob $"($original_file | path dirname)/cover.{($image_extensions | str join ',')}")
            if not ($covers | is-empty) {
                if ($covers | length) > 1 {
                    rm --force --recursive $temporary_directory
                    return {
                        file: $original_file
                        error: $"Found multiple files looking for the cover image file:\n($covers)\n"
                    }
                } else {
                    $covers | first
                }
            }
        }
    )

    if $original_cover != null {
        log debug $"Found the cover file (ansi yellow)($original_cover)(ansi reset)"
    }

    # todo Extract the cover from metadata?
    let cover = (
        if $original_cover != null {
            let target = [$temporary_directory ($original_cover | path basename)] | path join
            if ($original_file | str starts-with "minio:") {
                log debug $"Downloading the file (ansi yellow)($original_cover)(ansi reset) to (ansi yellow)($target)(ansi reset)"
                ^mc cp $original_cover $target
            } else {
                log debug $"Copying the file (ansi yellow)($original_cover)(ansi reset) to (ansi yellow)($target)(ansi reset)"
                cp $original_cover $target
            }
            $target
        }
    )

    let original_book_files = [($original_file | str replace "minio:" "")] | append $original_cover | append $original_opf
    log debug $"The original files for the book are (ansi yellow)($original_book_files)(ansi reset)"

    let input_format = ($file | path parse | get extension)
    let output_format = (
        if $input_format == "pdf" {
            "pdf"
        } else {
            "epub"
        }
    )

    let formats = (
        if $input_format == "acsm" {
            let epub = ($file | acsm_to_epub $temporary_directory | optimize_images_in_zip | polish_epub)
            { book: $epub }
        } else if $input_format == "epub" {
            { book: ($file | optimize_images_in_zip | polish_epub) }
        } else if $input_format == "pdf" {
            { book: $file }
        } else {
            rm --force --recursive $temporary_directory
            return {
                file: $original_file
                error: $"Unsupported input file type (ansi red_bold)($input_format)(ansi reset)"
            }
        }
    )

    let original_metadata = (
        $file | get_metadata $temporary_directory
    )

    log debug "Attempting to get the ISBN from existing metadata"
    let metadata_isbn = (
        $original_metadata | isbn_from_metadata
    )
    if $metadata_isbn != null {
        log debug $"Found the ISBN (ansi purple)($metadata_isbn)(ansi reset) in the book's metadata"
    }

    log debug "Attempting to get the ISBN from the first ten and last ten pages of the book"
    let book_isbn_numbers = (
        let isbn_numbers = $file | isbn_from_pages $temporary_directory;
        if ($isbn_numbers | is-empty) {
            # Check images for the ISBN if text doesn't work out.
            if "pdf" in $formats {
                let cbz = $formats.pdf | cbconvert --format "jpeg" --quality 90
                let isbn_from_cbz = $cbz | isbn_from_pages $temporary_directory
                rm $cbz
                if ($isbn_from_cbz | is-not-empty) {
                    $isbn_from_cbz
                }
            } else if "epub" in $formats {
                let isbn_from_epub = $formats.epub | isbn_from_pages $temporary_directory
                if ($isbn_from_epub | is-not-empty) {
                    $isbn_from_epub
                }
            }
        } else {
          $isbn_numbers
        }
    )
    if $book_isbn_numbers != null and ($book_isbn_numbers | is-not-empty) {
        log debug $"Found ISBN numbers in the book's pages: (ansi purple)($book_isbn_numbers)(ansi reset)"
    }

    # Determine the most likely ISBN from the metadata and pages
    let likely_isbn_from_pages_and_metadata = (
        if $metadata_isbn != null and $book_isbn_numbers != null {
            if ($book_isbn_numbers | is-empty) {
                log debug $"No ISBN numbers found in the pages of the book. Using the ISBN from the book's metadata (ansi purple)($metadata_isbn)(ansi reset)"
                $metadata_isbn
            } else if $metadata_isbn in $book_isbn_numbers {
                if ($book_isbn_numbers | length) == 1 {
                    log debug "Found an exact match between the ISBN in the metadata and the ISBN in the pages of the book"
                } else if ($book_isbn_numbers | length) > 10 {
                    rm --force --recursive $temporary_directory
                    return {
                        file: $original_file
                        error: $"Found more than 10 ISBN numbers in the pages of the book: (ansi purple)($book_isbn_numbers)(ansi reset)"
                    }
                }
                $metadata_isbn
            } else {
                # todo If only one number is available in the pages, should it be preferred?
                log warning $"The ISBN from the book's metadata, (ansi purple)($metadata_isbn)(ansi reset) not among the ISBN numbers found in the books pages: (ansi purple)($book_isbn_numbers)(ansi reset)."
                if ($book_isbn_numbers | length) == 1 {
                    log warning $"The ISBN from the book's metadata, (ansi purple)($metadata_isbn)(ansi reset) not among the ISBN numbers found in the books pages: (ansi purple)($book_isbn_numbers)(ansi reset)."
                    $book_isbn_numbers | first
                } else {
                    if $isbn == null {
                        rm --force --recursive $temporary_directory
                        return {
                            file: $original_file
                            error: $"The ISBN from the book's metadata, (ansi purple)($metadata_isbn)(ansi reset) not among the ISBN numbers found in the books pages: (ansi purple)($book_isbn_numbers)(ansi reset). Use the `--isbn` flag to set the ISBN instead."
                        }
                    } else {
                        log warning $"The ISBN from the book's metadata, (ansi purple)($metadata_isbn)(ansi reset) not among the ISBN numbers found in the books pages: (ansi purple)($book_isbn_numbers)(ansi reset)."
                    }
                }
            }
        } else if $metadata_isbn != null {
            log debug $"No ISBN numbers found in the pages of the book. Using the ISBN from the book's metadata (ansi purple)($metadata_isbn)(ansi reset)"
            $metadata_isbn
        } else if $book_isbn_numbers != null and ($book_isbn_numbers | is-not-empty) {
            if ($book_isbn_numbers | length) == 1 {
                log debug $"Found a single ISBN in the pages of the book: (ansi purple)($book_isbn_numbers | first)(ansi reset)"
                $book_isbn_numbers | first
            } else if ($book_isbn_numbers | length) > 10 {
                log warning $"Found more than 10 ISBN numbers in the pages of the book: (ansi purple)($book_isbn_numbers)(ansi reset)"
            } else {
                log warning $"Found multiple ISBN numbers in the pages of the book: (ansi purple)($book_isbn_numbers)(ansi reset)"
            }
        } else {
            log debug "No ISBN numbers found in the metadata or pages of the book"
        }
    )

    let isbn = (
        if $isbn == null {
            if $likely_isbn_from_pages_and_metadata == null {
                log warning $"Unable to determine the ISBN from metadata or the pages of the book"
            } else {
                $likely_isbn_from_pages_and_metadata
            }
        } else {
            if $likely_isbn_from_pages_and_metadata != null {
                if $isbn == $likely_isbn_from_pages_and_metadata {
                    log debug "The provided ISBN matches the one found using the book's metadata and pages"
                } else {
                    log warning $"The provided ISBN (ansi purple)($isbn)(ansi reset) does not match the one found using the book's metadata and pages (ansi purple)($likely_isbn_from_pages_and_metadata)(ansi reset)"
                }
            } else if $book_isbn_numbers != null and ($book_isbn_numbers | is-not-empty) {
                if $isbn in $book_isbn_numbers {
                    log debug $"The provided ISBN is among those found in the book's pages: (ansi purple)($book_isbn_numbers)(ansi reset)"
                } else {
                    log warning $"The provided ISBN is not among those found in the book's pages: (ansi purple)($book_isbn_numbers)(ansi reset)"
                }
            }
            $isbn
        }
    )
    if $isbn != null {
        log debug $"The ISBN is (ansi purple)($isbn)(ansi reset)"
    }

    let book = (
        $formats.book
        | (
            let input = $in;
            if $isbn == null or ($isbn | is-empty) {
                # Don't use Kobo unless we know the ISBN... or it will probably find something arbitrary and wrong instead of the actual book.
                let result = $input | fetch_book_metadata --allowed-plugins ["Google" "Amazon.com"] $temporary_directory
                if $result.opf == null {
                    {
                        book: $input
                        cover: null
                        opf: null
                    }
                } else {
                    let original_title = $original_metadata | title_from_metadata
                    let fetched_title = $result.opf | title_from_opf
                    if $fetched_title == $original_title {
                        $result
                    } else {
                        log warning $"The fetched title (ansi yellow)($fetched_title)(ansi reset) does not match the original title (ansi yellow)($original_title)(ansi reset). Ignoring metadata."
                        {
                            book: $input
                            cover: null
                            opf: null
                        }
                    }
                }
            } else {
                # todo output details of discovered metadata for verification
                let result = $input | fetch_book_metadata --isbn $isbn $temporary_directory
                if $result.opf == null {
                    {
                        book: $input
                        cover: null
                        opf: null
                    }
                } else {
                    let fetched_isbn = $result.opf | isbn_from_opf
                    if $fetched_isbn == null or ($fetched_isbn | is-empty) {
                        log warning "No ISBN in retrieved metadata!"
                        $result
                    } else if $fetched_isbn == $isbn {
                        $result
                    } else {
                        log info "Fetched ISBN doesn't match the ISBN used to search! Will attempt another search with only the Google and Amazon.com metadata sources"
                        let result = $input | fetch_book_metadata --allowed-plugins ["Google" "Amazon.com"] --isbn $isbn $temporary_directory
                        if $result.opf == null {
                            {
                                book: $input
                                cover: null
                                opf: null
                            }
                        } else {
                            let fetched_isbn = $result.opf | isbn_from_opf
                            if $fetched_isbn == null or ($fetched_isbn | is-empty) {
                                log warning "No ISBN in retrieved metadata!"
                                $result
                            } else if $fetched_isbn == $isbn {
                                $result
                            } else {
                                log warning "No metadata found!"
                                {
                                    book: $input
                                    cover: null
                                    opf: null
                                }
                            }
                        }
                    }
                }
            }
        )
        | (
            let input = $in;
            $input | update opf (
                if $input.opf != null {
                    # todo Should probably have a better way of merging metadata
                    $original_metadata.opf | merge $input.opf
                } else {
                    $original_metadata.opf
                }
            ) | update cover (
                if $cover != null {
                    $cover
                } else {
                    $input.cover
                }
            )
        )
        | export_book_to_directory $temporary_directory
        | embed_book_metadata $temporary_directory
    )

    let authors = (
      $book.opf
      | open
      | from xml
      | get content
      | where tag == "metadata"
      | first
      | get content
      | where tag == "creator"
      | where attributes.role == "aut"
      | par-each {|creator| $creator | get content | first | get content }
      | str trim --char ','
      | str trim
      | filter {|author| not ($author | is-empty)}
      | sort
    )
    log debug $"Authors: ($authors)"

    let authors_subdirectory = $authors | str join ", "
    let target_subdirectory = (
        [$authors_subdirectory]
        | append (
            if $output_format == "pdf" {
                $book.book | path parse | get stem
            } else {
                null
            }
        )
        | path join
    )
    let minio_target_directory = (
        [$minio_alias $minio_path $target_subdirectory]
        | path join
        | sanitize_minio_filename
    )
    log debug $"MinIO target directory: ($minio_target_directory)"
    let minio_target_destination = (
        let components = $book.book | path parse;
        {
            parent: $minio_target_directory
            stem: $components.stem
            extension: $components.extension
        } | path join | sanitize_minio_filename
    )
    log debug $"MinIO target destination: ($minio_target_destination)"
    let opf_target_destination = (
        if $output_format == "pdf" {
            [
                $minio_target_directory
                ($book.opf | path basename)
            ] | path join
        }
    )
    let cover_target_destination = (
        if $output_format == "pdf" {
            [
                $minio_target_directory
                ($book.cover | path basename)
            ] | path join
        }
    )
    if $skip_upload {
        mkdir $target_subdirectory
        if $output_format == "pdf" {
          mv $book.book $book.cover $book.opf $target_subdirectory
        } else {
          mv $book.book $target_subdirectory
        }
    } else {
        log info $"Uploading (ansi yellow)($book.book)(ansi reset) to (ansi yellow)($minio_target_destination)(ansi reset)"
        ^mc mv $book.book $minio_target_destination
        if $output_format == "pdf" {
          log info $"Uploading (ansi yellow)($book.opf)(ansi reset) to (ansi yellow)($opf_target_destination)(ansi reset)"
          ^mc mv $book.opf $opf_target_destination
          log info $"Uploading (ansi yellow)($book.cover)(ansi reset) to (ansi yellow)($cover_target_destination)(ansi reset)"
          ^mc mv $book.cover $cover_target_destination
        }
    }

    if $delete {
        let uploaded_paths = (
            [$minio_target_destination]
            | append $cover_target_destination
            | append $opf_target_destination
        )
        log debug $"Uploaded paths: ($uploaded_paths)"
        if ($original_file | str starts-with "minio:") {
            if not $skip_upload {
                for original in $original_book_files {
                    if $original not-in $uploaded_paths {
                        log info $"Deleting the file (ansi yellow)($original)(ansi reset) on MinIO"
                        ^mc rm $original
                    }
                }
            }
        } else {
            if $output_directory != null {
                for original in $original_book_files {
                    let output = [$output_directory ($original | path basename)] | path join
                    if $original != $output {
                        log info $"Deleting the file (ansi yellow)($original)(ansi reset)"
                        rm $original
                    }
                }
            } else {
                for original in $original_book_files {
                    rm $original
                }
            }
        }
    }
    log debug $"Removing the working directory (ansi yellow)($temporary_directory)(ansi reset)"
    rm --force --recursive $temporary_directory
    {
        file: $original_file
    }

    # } catch {|err|
    #     rm --force --recursive $temporary_directory
    #     log error $"Import of (ansi red)($original_file)(ansi reset) failed!\n($err.msg)\n"
    #     {
    #         file: $original_file
    #         error: $err.msg
    #     }
    # }
    }

    if $ereader != null and not $no_copy_to_ereader {
      if (^findmnt --target $ereader_target_directory | complete | get exit_code) == 0 {
        ^udisksctl unmount --block-device ("/dev/disk/by-label/" | path join $ereader_disk_label) --no-user-interaction
      }
    }

    $results | to json | print

    let errors = $results | default null error | where error != null
    if ($errors | is-not-empty) {
        log error $"(ansi red)Failed to import the following files due to errors!(ansi reset)"
        $errors | get file | $"(ansi red)($in)(ansi reset)" | print --stderr
        exit 1
    }
}
