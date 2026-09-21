local Hardcover = {
  STATUS = {
    TO_READ = 1,
    READING = 2,
    FINISHED = 3,
    DNF = 5,
  },
  READING_FORMAT = {
    PHYSICAL = 1,
    AUDIOBOOK = 2,
    EBOOK = 4,
  },
  PRIVACY = {
    PUBLIC = 1,
    FOLLOWS = 2,
    PRIVATE = 3,
  },
  CATEGORY = {
    TAG = "Tag",
  },
  ERROR = {
    JWT = "invalid-jwt",
    TOKEN = "Unable to verify token",
  }
}

return Hardcover
