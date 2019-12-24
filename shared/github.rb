# Shared functions for github actions

require "json"
require "open3"

class Executor
  def execute(cmd)
    puts "Running: #{cmd}"
    Open3.capture3(cmd)
  end
end

class GithubClient
  attr_reader :client

  def initialize
    unless ENV.key?("GITHUB_TOKEN")
      raise "No GITHUB_TOKEN env var found. Please make this available via the github actions workflow\nhttps://help.github.com/en/articles/virtual-environments-for-github-actions#github_token-secret"
    end

    client = Octokit::Client.new(access_token: ENV["GITHUB_TOKEN"])
  end

  def event
    unless ENV.key?("GITHUB_EVENT_PATH")
      raise "No GITHUB_EVENT_PATH env var found. This script is designed to run via github actions, which will provide the github event via this env var."
    end

    @evt ||= JSON.parse File.read(ENV["GITHUB_EVENT_PATH"])
  end

  def repo
    name = event.dig("repository", "name")
    owner = event.dig("repository", "owner", "login")
    [owner, name].join("/")
  end

  def pull_request_files(repo, pr_number)
    client.pull_request_files(repo, pr_number)
  end

  def create_blob(repo, base64content, encoding)
    client.create_blob(repo, base64content, encoding)
  end

  def ref(repo, ref)
    client.ref(repo, ref)
  end

  def commit(repo, sha_latest_commit)
    client.commit(repo, sha_latest_commit)
  end

  def create_tree(repo, changes, hash)
    client.create_tree(repo, changes, hash)
  end

  def create_commit(repo, commit_message, sha_new_tree, sha_latest_commit)
    client.create_commit(repo, commit_message, sha_new_tree, sha_latest_commit)
  end

  def update_ref(repo, ref, sha_new_commit)
    client.update_ref(repo, ref, sha_new_commit)
  end

  def create_pull_request_review(repo, pr_number, hash)
    client.create_pull_request_review(repo, pr_number, hash)
  end
end

def github
  @client ||= GithubClient.new
end

def event
  github.event
end

def repo
  github.repo
end

def pr_number
  event.dig("pull_request", "number")
end

def branch
  event.dig("pull_request", "head", "ref")
end

def create_blobs(files)
  files.map do |file_name|
    content = File.read(file_name)
    blob_sha = github.create_blob(repo, Base64.encode64(content), "base64")
    {path: file_name, mode: "100644", type: "blob", sha: blob_sha}
  end
end

def files_in_pr
  github.pull_request_files(repo, pr_number)
    .map(&:filename)
    .sort
    .uniq
end

def execute(cmd)
  Executor.new.execute(cmd)
end

def commit_changes(message)
  files = modified_files
  if files.any?
    puts "Committing changes to:\n  #{files.join("\n  ")}"
    commit_files(branch, files, message)
  end
end

def modified_files
  stdout, _stderr, _status = execute("git status --porcelain=1 --untracked-files=no")

  stdout
    .split("\n")
    .map { |line| line.sub(" M ", "") }
end

def commit_files(branch, files, commit_message)
  ref = "heads/#{branch}"
  sha_latest_commit = github.ref(repo, ref).object.sha
  sha_base_tree = github.commit(repo, sha_latest_commit).commit.tree.sha
  changes = create_blobs files
  sha_new_tree = github.create_tree(repo, changes, {base_tree: sha_base_tree}).sha
  sha_new_commit = github.create_commit(repo, commit_message, sha_new_tree, sha_latest_commit).sha
  github.update_ref(repo, ref, sha_new_commit)
end

def reject_pr(message)
  puts "Requesting changes..."
  puts message

  github.create_pull_request_review(
    repo,
    pr_number,
    {
      body: message,
      event: "REQUEST_CHANGES",
    }
  )
  exit 1
end
